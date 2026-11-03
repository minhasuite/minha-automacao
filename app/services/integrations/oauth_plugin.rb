module Integrations
  # catalogo: base das integrações de nuvem com OAuth2 pelo app do PRÓPRIO
  # dono (client id e secret criados no portal de desenvolvedor do serviço,
  # cifrados aqui; o que criar em cada serviço está em docs/catalogo.md). O
  # formulário sai dos campos (SchemaPlugin); depois dele vem o passo
  # "Entrar com …" (partial genérica `connect/_oauth`), o retorno guarda o
  # refresh token e a varredura segue igual. `api` renova o access token quando
  # vence ou quando o serviço recusa (401, uma vez).
  #
  #   class FooPlugin < OauthPlugin
  #     oauth authorize: "https://foo/oauth/authorize", token: "https://foo/oauth/token", scope: "read write"
  #     def self.entries(integration) = api(integration, :get, "https://foo/api/devices")…
  #   end
  class OauthPlugin < SchemaPlugin
    texts "pt-BR" => { fields: { client_id: "Client ID do seu app", client_secret: "Client secret do seu app" },
                       sign_in: "Entrar com %{name}", sign_in_hint: "Abre a página do serviço para autorizar o Minha Automação. No app que você criou lá, cadastre este endereço de retorno:",
                       connected: "%{name} conectado: %{n} aparelho(s).", refused: "O serviço recusou: %{error}", no_token: "Falta entrar com a conta (passo de login)." },
          en: { fields: { client_id: "Your app's client ID", client_secret: "Your app's client secret" },
                sign_in: "Sign in with %{name}", sign_in_hint: "Opens the service's page to authorize Minha Automação. In the app you created there, register this redirect address:",
                connected: "%{name} connected: %{n} device(s).", refused: "The service refused: %{error}", no_token: "You still need to sign in with the account (login step)." },
          es: { fields: { client_id: "Client ID de tu app", client_secret: "Client secret de tu app" },
                sign_in: "Entrar con %{name}", sign_in_hint: "Abre la página del servicio para autorizar Minha Automação. En la app que creaste allí, registra esta dirección de retorno:",
                connected: "%{name} conectado: %{n} aparato(s).", refused: "El servicio rechazó: %{error}", no_token: "Falta entrar con la cuenta (paso de inicio de sesión)." }
    field :client_id, required: true
    field :client_secret, secret: true, required: true

    class << self
      def oauth(authorize:, token:, scope: nil, params: {})
        @oauth = { authorize: authorize, token: token, scope: scope, params: params }
      end

      def oauth_config = @oauth || (superclass.respond_to?(:oauth_config) ? superclass.oauth_config : {})
      # Endereços que dependem da integração (Nest: o id do projeto vai na URL).
      def authorize_url(_integration) = oauth_config[:authorize]

      def login(integration, form)
        plain = fields.reject(&:secret).to_h { |f| [ f.key, form[f.key].to_s.strip ] }.compact_blank
        integration.settings = integration.settings.merge(plain).merge("account" => title)
        values = fields.select(&:secret).to_h { |f| [ f.key, form[f.key].to_s.strip ] }.compact_blank
        integration.credentials = integration.secrets.merge(values).to_json if values.any?
        integration.status = "pending" if integration.new_record?
        integration.save!
        outcome(:connect, integration: integration)
      end

      def connect_locals(integration, params)
        q = { client_id: conf(integration, :client_id), response_type: "code", redirect_uri: params[:redirect_uri], scope: oauth_config[:scope],
              state: Integrations.oauth_state(integration), **oauth_config[:params] }.compact
        { auth_url: "#{authorize_url(integration)}?#{q.to_query}", redirect_uri: params[:redirect_uri] }
      end

      def oauth_callback(integration, params)
        raise Integrations::Error, text(:no_token) if params[:code].blank?

        integration.merge_secrets!(tokens(integration, grant_type: "authorization_code", code: params[:code], redirect_uri: params[:redirect_uri]))
        r = Integrations.sync!(integration)
        outcome(:found, integration: integration, notice: text(:connected, name: title, n: r[:found]))
      rescue Integrations::Error, SafeHttp::Error => e
        integration.error!(e.message)
        outcome(:connect, integration: integration, alert: text(:refused, error: e.message))
      end

      # Pedido de token (código ou refresh) → {"access_token", "refresh_token", "expires_at"}.
      def tokens(integration, **form)
        form = form.merge(client_id: conf(integration, :client_id), client_secret: conf(integration, :client_secret))
        res = SafeHttp.request("POST", oauth_config[:token], headers: { "Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/json" },
                                                            body: URI.encode_www_form(form), timeout: 15)
        body = begin
          JSON.parse(res.body)
        rescue JSON::ParserError
          {}
        end
        unless res.status == 200
          e = Integrations::Error.new(body["error_description"] || body["error"] || "HTTP #{res.status}")
          raise res.status.between?(400, 499) ? Integrations.auth(e) : e
        end
        { "access_token" => body["access_token"], "refresh_token" => body["refresh_token"], "expires_at" => Time.current.to_i + body["expires_in"].to_i }.compact
      end

      def access_token(integration, force: false)
        s = integration.secrets
        raise Integrations.auth(Integrations::Error.new(text(:no_token))) if s["refresh_token"].blank? && s["access_token"].blank?
        return s["access_token"] if !force && s["access_token"].present? && s["expires_at"].to_i > Time.current.to_i + 60

        fresh = tokens(integration, grant_type: "refresh_token", refresh_token: s["refresh_token"])
        integration.merge_secrets!(fresh)
        fresh["access_token"]
      end

      def api_headers = { "Accept" => "application/json" }

      # Chamada autenticada → JSON (corpo vazio = {}). 401 renova o token uma vez.
      def api(integration, method, url, body = nil, retry_auth: true)
        headers = api_headers.merge("Authorization" => "Bearer #{access_token(integration, force: !retry_auth)}")
        headers["Content-Type"] ||= "application/json" if body
        res = SafeHttp.request(method.to_s.upcase, url, headers: headers, body: body&.to_json, timeout: 20)
        return api(integration, method, url, body, retry_auth: false) if res.status == 401 && retry_auth

        data = res.body.present? ? JSON.parse(res.body) : {}
        unless res.status.between?(200, 299)
          e = Integrations::Error.new("#{title}: #{api_error(data) || "HTTP #{res.status}"}")
          raise [ 401, 403 ].include?(res.status) ? Integrations.auth(e) : e
        end
        data
      rescue SafeHttp::Error, JSON::ParserError => e
        raise Integrations::Error, "#{title}: #{e.message}"
      end

      def api_error(data) = data.is_a?(Hash) ? (data.dig("error", "message") || data["message"] || data["error_description"] || (data["error"] if data["error"].is_a?(String))) : nil
    end
  end
end
