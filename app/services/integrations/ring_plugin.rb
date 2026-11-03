module Integrations
  # Ring (catalogo): campainhas, câmeras e alarmes da conta Ring pela API do
  # app (login com e-mail, senha e o código de 2 etapas que a Ring manda;
  # depois só o refresh token fica guardado, a senha não). Bateria, última
  # campainha e último movimento (event), e a luz das câmeras com holofote.
  class RingPlugin < SchemaPlugin
    describe key: "ring", title: "Ring", icon: "bell",
             description: "Campainhas e câmeras Ring da conta: bateria, quem tocou e movimento como eventos para automações, e a luz das câmeras com holofote."
    texts "pt-BR" => { fields: { otp: "Código de 2 etapas" }, hints: { otp: "a Ring manda por SMS ou e-mail depois do primeiro Continuar" },
                       points: { ding: "Campainha", motion: "Movimento", floodlight: "Holofote" },
                       need_code: "A Ring mandou um código (SMS ou e-mail): digite em \"Código de 2 etapas\" e continue.", refused: "A Ring recusou o login: %{error}" },
          en: { title: "Ring", description: "Ring doorbells and cameras on your account: battery, who rang and motion as events for automations, and floodlight cameras' light.",
                fields: { otp: "2-step code" }, hints: { otp: "Ring sends it by SMS or e-mail after the first Continue" },
                points: { ding: "Doorbell", motion: "Motion", floodlight: "Floodlight" },
                need_code: "Ring sent a code (SMS or e-mail): type it in \"2-step code\" and continue.", refused: "Ring refused the login: %{error}" },
          es: { title: "Ring", description: "Timbres y cámaras Ring de la cuenta: batería, quién tocó y movimiento como eventos para automatizaciones, y la luz de las cámaras con reflector.",
                fields: { otp: "Código de 2 pasos" }, hints: { otp: "Ring lo envía por SMS o e-mail tras el primer Continuar" },
                points: { ding: "Timbre", motion: "Movimiento", floodlight: "Reflector" },
                need_code: "Ring envió un código (SMS o e-mail): escríbelo en \"Código de 2 pasos\" y continúa.", refused: "Ring rechazó el inicio de sesión: %{error}" }
    field :username, required: true
    field :password, secret: true
    field :otp

    TOKEN = "https://oauth.ring.com/oauth/token".freeze
    API = "https://api.ring.com/clients_api".freeze
    CLIENT = "ring_official_android".freeze

    class << self
      # Senha e código só passam pelo login: o que fica é o refresh token.
      def login(integration, form)
        integration.settings = integration.settings.merge("account" => form[:username].to_s.strip.presence || integration.settings["account"]).except("otp")
        if form[:password].present?
          tokens = token_request({ grant_type: "password", username: form[:username].to_s.strip, password: form[:password].to_s, scope: "client", client_id: CLIENT },
                                 form[:otp].to_s.strip.presence)
          integration.credentials = tokens.to_json
        end
        integration.save!
        r = Integrations.sync!(integration)
        outcome(:found, integration: integration, notice: text(:read, n: r[:found]))
      rescue Integrations::Error => e
        integration.save! if integration.new_record? && e.message == text(:need_code)
        outcome(integration.persisted? ? :connect : :form, integration: integration.persisted? ? integration : nil, alert: e.message)
      end

      def token_request(form, otp = nil)
        headers = { "Content-Type" => "application/x-www-form-urlencoded", "2fa-support" => "true", "hardware_id" => "minha-automacao" }
        headers["2fa-code"] = otp if otp
        res = SafeHttp.request("POST", TOKEN, headers: headers, body: URI.encode_www_form(form), timeout: 15)
        body = JSON.parse(res.body.presence || "{}")
        raise Integrations::Error, text(:need_code) if res.status == 412
        raise Integrations.auth(Integrations::Error.new(text(:refused, error: body["error_description"] || body["error"] || res.status))) unless res.status == 200

        { "access_token" => body["access_token"], "refresh_token" => body["refresh_token"], "expires_at" => Time.current.to_i + body["expires_in"].to_i }
      rescue SafeHttp::Error, JSON::ParserError => e
        raise Integrations::Error, "Ring: #{e.message}"
      end

      def access_token(integration)
        s = integration.secrets
        return s["access_token"] if s["access_token"].present? && s["expires_at"].to_i > Time.current.to_i + 60
        raise Integrations.auth(Integrations::Error.new(text(:refused, error: "login"))) if s["refresh_token"].blank?

        fresh = token_request(grant_type: "refresh_token", refresh_token: s["refresh_token"], client_id: CLIENT, scope: "client")
        integration.merge_secrets!(fresh)
        fresh["access_token"]
      end

      def api(integration, method, path, body = nil)
        res = SafeHttp.request(method.to_s.upcase, "#{API}/#{path}", headers: { "Authorization" => "Bearer #{access_token(integration)}", "Content-Type" => "application/json" },
                                                                    body: body&.to_json, timeout: 15)
        raise Integrations.auth(Integrations::Error.new(text(:refused, error: res.status))) if res.status == 401
        raise Integrations::Error, "Ring: HTTP #{res.status}" unless res.status.between?(200, 299)

        res.body.present? ? JSON.parse(res.body) : {}
      rescue SafeHttp::Error, JSON::ParserError => e
        raise Integrations::Error, "Ring: #{e.message}"
      end

      def entries(integration)
        devs = api(integration, :get, "ring_devices")
        %w[doorbots authorized_doorbots stickup_cams].flat_map { |k| Array(devs[k]).map { |d| d.merge("kind_of" => k) } }.map do |d|
          pts = [ (point("battery", unit: "%", device_class: "battery") if d["battery_life"]), point("motion", "event", icon: "eye"),
                  (point("ding", "event", icon: "bell") if d["kind_of"] != "stickup_cams"),
                  (point("floodlight", "onoff", icon: "light-bulb") if d["led_status"]) ]
          entry(id: "ring:#{d['id']}", name: d["description"].presence || "Ring", manufacturer: "Ring", model: d["kind"], address: { "id" => d["id"].to_s },
                poll_s: 60, points: pts)
        end
      end

      # Eventos novos desde a última leitura viram o valor do ponto event.
      def read(device)
        i = device.integration
        id = device.address["id"]
        d = api(i, :get, "ring_devices").values_at("doorbots", "authorized_doorbots", "stickup_cams").flatten.compact.find { |x| x["id"].to_s == id }.to_h
        last = Array(api(i, :get, "doorbots/#{id}/history?limit=5")).max_by { |e| e["created_at"].to_s }
        out = { "battery" => d["battery_life"]&.to_i, "floodlight" => (d["led_status"] == "on" if d["led_status"]) }
        if last && last["created_at"].to_s > device.address["last_event"].to_s
          device.update_columns(address: device.address.merge("last_event" => last["created_at"]))
          out[last["kind"] == "ding" ? "ding" : "motion"] = { "at" => last["created_at"], "answered" => last["answered"] }
        end
        out
      end

      def write(point, value) = api(point.device.integration, :put, "doorbots/#{point.device.address['id']}/floodlight_light_#{value ? 'on' : 'off'}")
    end
  end
end
