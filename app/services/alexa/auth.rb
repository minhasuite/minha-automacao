require "net/http"

module Alexa
  # Sessão própria da Alexa (Lote 3, G31), sem depender do HA: o mesmo
  # caminho do app Alexa e do alexa_media (alexapy/alexa-cookie2), só que o
  # login acontece no navegador da própria pessoa, na página da Amazon. Assim
  # a senha e o código de duas etapas (2FA, captcha) nunca passam por aqui.
  #
  # 1. `start!`: gera o número de série deste "aparelho" e o PKCE e devolve o
  #    link de login da Amazon (OAuth do app, `openid.oa2`).
  # 2. A pessoa entra (senha, 2FA) e cai numa página "não encontrada" da
  #    Amazon (`/ap/maplanding?...authorization_code=...`); copia o endereço.
  # 3. `finish!`: troca o código pelo registro do aparelho
  #    (`/auth/register` → refresh token + cookies) e lê o `csrf`.
  # 4. `refresh!`: cookies novos a partir do refresh token
  #    (`/ap/exchangetoken/cookies`), chamado sozinho quando a Amazon recusa.
  #
  # Credenciais da integração (cifradas): {cookies, refresh_token, serial,
  # verifier (só durante o login)}. Conta antiga (cookies colados do HA) é o
  # mapa de cookies direto e continua lida por `cookies`.
  module Auth
    class Error < Client::Error; end

    DEVICE_TYPE = "A2IVLV5VM2W81".freeze # app Alexa no iOS
    APP_VERSION = "2.2.556530.0".freeze
    REGISTER_URL = "https://api.amazon.com/auth/register".freeze
    # Domínios em que a Alexa atende (a conta é a da loja da Amazon do país).
    DOMAINS = %w[amazon.com.br amazon.com amazon.com.mx amazon.ca amazon.co.uk amazon.de amazon.fr amazon.it amazon.es amazon.in amazon.co.jp amazon.com.au].freeze
    DEFAULT_DOMAIN = "amazon.com.br".freeze
    NOT_COOKIES = %w[cookies refresh_token serial verifier].freeze

    module_function

    def domain(integration) = integration.settings["domain"].presence_in(DOMAINS) || DEFAULT_DOMAIN
    def alexa_host(domain) = "alexa.#{domain}"

    # Cookies da sessão (formato novo ou o mapa antigo colado do HA).
    def cookies(integration)
      s = integration.secrets
      s["cookies"].is_a?(Hash) ? s["cookies"] : s.except(*NOT_COOKIES)
    end

    def refreshable?(integration) = integration.secrets["refresh_token"].present?

    # Link de login; reaproveita o PKCE pendente (recarregar a tela não invalida o link aberto).
    def start!(integration)
      s = integration.secrets
      pending = { "serial" => s["serial"].presence || SecureRandom.hex(16).upcase, "verifier" => s["verifier"].presence || b64url(SecureRandom.random_bytes(32)) }
      integration.merge_secrets!(pending) if pending != s.slice("serial", "verifier")
      login_url(domain(integration), pending["serial"], pending["verifier"])
    end

    def client_id(serial) = "#{serial}##{DEVICE_TYPE}".unpack1("H*")

    def login_url(domain, serial, verifier)
      tld = domain.split(".").last
      handle = domain == "amazon.com" ? "amzn_dp_project_dee_ios" : "amzn_dp_project_dee_ios_#{tld}"
      query = {
        "openid.return_to" => "https://www.#{domain}/ap/maplanding", "openid.assoc_handle" => handle,
        "openid.identity" => "http://specs.openid.net/auth/2.0/identifier_select", "pageId" => handle, "accountStatusPolicy" => "P1",
        "openid.claimed_id" => "http://specs.openid.net/auth/2.0/identifier_select", "openid.mode" => "checkid_setup",
        "openid.ns.oa2" => "http://www.amazon.com/ap/ext/oauth/2", "openid.oa2.client_id" => "device:#{client_id(serial)}",
        "openid.ns.pape" => "http://specs.openid.net/extensions/pape/1.0", "openid.oa2.response_type" => "code",
        "openid.ns" => "http://specs.openid.net/auth/2.0", "openid.pape.max_auth_age" => "0", "openid.oa2.scope" => "device_auth_access",
        "openid.oa2.code_challenge_method" => "S256", "openid.oa2.code_challenge" => b64url(Digest::SHA256.digest(verifier)), "language" => "pt_BR"
      }
      "https://www.#{domain}/ap/signin?#{URI.encode_www_form(query)}"
    end

    # Endereço da página final (ou só o código) → conta registrada e cookies gravados.
    def finish!(integration, return_url)
      s = integration.secrets
      raise Error, "Abra o link de login de novo: o pedido expirou." if s["verifier"].blank?

      code = authorization_code(return_url) or raise Error, "Não achei o código no endereço colado. Copie o endereço inteiro da página da Amazon depois de entrar."
      d = domain(integration)
      body = { "requested_extensions" => %w[device_info customer_info],
               "cookies" => { "website_cookies" => [], "domain" => ".#{d}" },
               "registration_data" => { "domain" => "Device", "app_version" => APP_VERSION, "device_type" => DEVICE_TYPE,
                                        "device_name" => "%FIRST_NAME%'s%DUPE_STRATEGY_1ST%Minha Automação", "os_version" => "16.6",
                                        "device_serial" => s["serial"], "device_model" => "iPhone", "app_name" => "Minha Automação", "software_version" => "1" },
               "auth_data" => { "use_global_authentication" => "true", "client_id" => client_id(s["serial"]), "authorization_code" => code,
                                "code_verifier" => s["verifier"], "code_algorithm" => "SHA-256", "client_domain" => "DeviceLegacy" },
               "requested_token_type" => %w[bearer mac_dms website_cookies store_authentication_cookie] }
      res = JSON.parse(http_post(REGISTER_URL, body.to_json, "Content-Type" => "application/json").body)
      ok = res.dig("response", "success") or raise Integrations.auth(Error.new("A Amazon recusou o login (#{res.dig('response', 'error', 'code') || 'sem detalhe'}). Abra o link e entre de novo."))
      refresh = ok.dig("tokens", "bearer", "refresh_token") or raise Error, "A Amazon não devolveu o token da sessão."
      jar = Array(ok.dig("tokens", "website_cookies")).to_h { |c| [ c["Name"], c["Value"].to_s.delete('"') ] }
      jar = with_csrf(d, jar)
      integration.credentials = { "cookies" => jar, "refresh_token" => refresh, "serial" => s["serial"] }.to_json
      name = ok.dig("extensions", "customer_info", "given_name") || ok.dig("extensions", "customer_info", "name")
      integration.settings = integration.settings.merge("host" => alexa_host(d), "domain" => d, "account" => name.presence || integration.settings["account"], "login" => "app").compact
      integration.save!
      jar
    rescue JSON::ParserError
      raise Error, "Resposta ilegível da Amazon no login."
    end

    # Cookies novos pelo refresh token (sem senha). Recusou = precisa entrar de novo.
    def refresh!(integration)
      s = integration.secrets
      raise Integrations.auth(Error.new("Sessão da Alexa sem renovação: entre de novo pela conta Amazon.")) if s["refresh_token"].blank?

      d = domain(integration)
      form = { "app_name" => "Amazon Alexa", "requested_token_type" => "auth_cookies", "domain" => "www.#{d}",
               "source_token_type" => "refresh_token", "source_token" => s["refresh_token"] }
      res = http_post("https://www.#{d}/ap/exchangetoken/cookies", URI.encode_www_form(form),
                      "Content-Type" => "application/x-www-form-urlencoded", "x-amzn-identity-auth-domain" => "api.#{d}")
      tokens = JSON.parse(res.body).dig("response", "tokens", "cookies")
      raise Integrations.auth(Error.new("A Amazon não renovou a sessão: entre de novo pela conta Amazon.")) unless tokens.is_a?(Hash)

      jar = with_csrf(d, tokens.values.flatten.to_h { |c| [ c["Name"], c["Value"].to_s.delete('"') ] })
      integration.merge_secrets!("cookies" => jar)
      integration.update!(settings: integration.settings.merge("renewed_at" => Time.current.iso8601))
      jar
    rescue JSON::ParserError
      raise Error, "Resposta ilegível da Amazon ao renovar a sessão."
    end

    def authorization_code(text)
      text = text.to_s.strip
      return text if text.match?(/\A[A-Za-z0-9_-]{10,}\z/) # colou só o código

      query = URI.parse(text).query.to_s
      URI.decode_www_form(query).to_h["openid.oa2.authorization_code"].presence
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    # O site da Alexa entrega o cookie `csrf` na primeira leitura; as ações exigem ele.
    def with_csrf(domain, jar)
      %w[/api/language /spa/index.html].each do |path|
        break if jar["csrf"].present?

        uri = URI("https://#{alexa_host(domain)}#{path}")
        req = Net::HTTP::Get.new(uri, "Cookie" => jar.map { |k, v| "#{k}=#{v}" }.join("; "), "User-Agent" => Client::USER_AGENT)
        res = Net::HTTP.start(uri.host, 443, use_ssl: true, open_timeout: 5, read_timeout: 15) { |h| h.request(req) }
        Array(res.get_fields("set-cookie")).each do |c|
          k, v = c.split(";").first.to_s.split("=", 2)
          jar[k.strip] = v.to_s if k.present?
        end
      end
      jar
    rescue SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError
      jar
    end

    def http_post(url, body, headers)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri, headers.merge("User-Agent" => Client::USER_AGENT, "Accept" => "application/json"))
      req.body = body
      Net::HTTP.start(uri.host, 443, use_ssl: true, open_timeout: 5, read_timeout: 20) { |h| h.request(req) }
    rescue SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      raise Error, "Sem conexão com a Amazon (#{e.class.name.demodulize})."
    end

    def b64url(bytes) = Base64.urlsafe_encode64(bytes, padding: false)
  end
end
