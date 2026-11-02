module Drivers
  # IKEA Dirigera (integ2): hub pela API local (HTTPS 8443, certificado
  # próprio, `/v1`). Pareamento OAuth com PKCE e o botão de ação do hub: o
  # primeiro "Adicionar" pede o código; com o botão apertado, o segundo troca
  # pelo token (cifrado na integração). Tipos → pontos pelo
  # `config/device_maps/dirigera.yml`; leitura a cada 30 s e logo depois de
  # cada comando (PATCH /v1/devices/:id). Endereço do aparelho {device_id};
  # ponto {attr, set?, invert?}.
  class Dirigera
    MAP = YAML.load_file(Rails.root.join("config/device_maps/dirigera.yml")).freeze
    ATTRS = %w[name capability unit device_class state_class min max step icon].freeze

    def self.base(integration) = "https://#{integration.settings['host']}:#{(integration.settings['port'].presence || 8443).to_i}/v1"

    def self.call(integration, method, path, body = nil)
      LanHttp.call(method, "#{base(integration)}#{path}", body: body, insecure: true, headers: { "Authorization" => "Bearer #{integration.secrets['token']}" })
    end

    # Sem token: 1º passo pede o código (guarda o verificador); 2º troca pelo token.
    def self.pair!(integration)
      s = integration.secrets
      if s["code"].blank?
        verifier = SecureRandom.urlsafe_base64(96)[0, 128]
        challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        q = URI.encode_www_form(audience: "homesmart.local", response_type: "code", code_challenge: challenge, code_challenge_method: "S256")
        code = LanHttp.get("#{base(integration)}/oauth/authorize?#{q}", insecure: true)["code"]
        integration.update!(credentials: s.merge("code" => code, "verifier" => verifier).to_json)
        raise Integrations::Error, "Aperte o botão de ação embaixo do Dirigera e clique em Adicionar de novo (em até 1 min)."
      end

      body = URI.encode_www_form(code: s["code"], name: "minha-automacao", grant_type: "authorization_code", code_verifier: s["verifier"])
      token = begin
        LanHttp.post("#{base(integration)}/oauth/token", body, headers: { "Content-Type" => "application/x-www-form-urlencoded" }, insecure: true)["access_token"]
      rescue Integrations::Error
        nil
      end
      integration.update!(credentials: s.except("code", "verifier").merge("token" => token).compact.to_json)
      token or raise Integrations::Error, "O Dirigera não liberou o acesso. Clique em Adicionar, aperte o botão do hub e clique de novo."
    end

    def self.inventory(integration)
      pair!(integration) if integration.secrets["token"].blank?
      Array(call(integration, :get, "/devices")).filter_map do |d|
        a = d["attributes"].to_h
        points = points_for(d["deviceType"], a)
        next if points.empty?

        { "id" => "dirigera:#{d['id']}", "kind" => "dirigera", "name" => a["customName"].presence || a["model"] || d["deviceType"],
          "manufacturer" => a["manufacturer"].presence || "IKEA", "model" => a["model"], "category" => "IKEA", "room" => d.dig("room", "name"),
          "online" => d["isReachable"] != false, "poll_s" => 30, "address" => { "device_id" => d["id"] }, "points" => points }
      end
    end

    def self.points_for(type, attrs)
      lines = MAP.dig("types", type.to_s) or return []

      (lines + MAP["common"]).filter_map do |x|
        { "capability" => "measure" }.merge(x.slice(*ATTRS)).merge("address" => x.slice("attr", "set", "invert")) if attrs.key?(x["attr"])
      end
    end

    def self.value(point, attrs)
      raw = attrs[point.address["attr"]]
      return if raw.nil?

      raw = 100 - raw.to_i if point.address["invert"]
      point.from_raw(raw)
    end

    def self.poll(device)
      d = call(device.integration, :get, "/devices/#{device.address['device_id']}")
      device.update_columns(status: d["isReachable"] == false ? "offline" : "online", last_seen_at: Time.current)
      device.points.reject(&:disabled).each { |p| (v = value(p, d["attributes"].to_h)).nil? || p.report!(v) }
    end

    def self.unavailable!(device) = Drivers.offline!(device)

    def execute(point, command, value)
      v = Points::Command.new(point, command, value).new_value
      a = point.address
      raw = a["invert"] ? 100 - v.to_i : v
      self.class.call(point.device.integration, :patch, "/devices/#{point.device.address['device_id']}", [ { attributes: { (a["set"] || a["attr"]) => raw } } ])
      self.class.poll(point.device)
    end
  end
end
