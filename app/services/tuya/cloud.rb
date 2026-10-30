require "net/http"

module Tuya
  # Conta Smart Life / Tuya Smart pelo mesmo caminho da integração oficial
  # `tuya` do HA (tuya-device-sharing-sdk): login por QR code no app, sem conta
  # Tuya IoT Core. A nuvem só serve para DESCOBRIR os aparelhos (casa, cômodo,
  # categoria, local_key e o mapa de dps); o controle continua local pelo
  # `tuya_local`. Nada aqui manda comando.
  #
  # Credenciais da integração (cifradas): user_code, qr (token do QR em
  # andamento), endpoint, terminal_id, token ({t, expire_time, uid,
  # access_token, refresh_token}). Pedido assinado e cifrado (AES-GCM) como no
  # SDK; o access token é renovado sozinho e gravado de volta.
  class Cloud
    class Error < Integrations::Error; end

    LOGIN_HOST = "https://apigw.iotbing.com".freeze
    CLIENT_ID = "HA_3y9q4ak7g4ephrvke".freeze # o mesmo do HA
    SCHEMA = "haauthorize".freeze
    NONCE = "ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678".chars.freeze

    # Códigos que viram ponto (nome, unidade, capacidade): dado em config/device_maps/tuya.yml.
    MAP = YAML.load_file(Rails.root.join("config/device_maps/tuya.yml")).freeze
    SKIP = Regexp.new(MAP["skip"])
    PROBLEM = Regexp.new(MAP["problem"])

    # --- login por QR (sem token ainda) --------------------------------------

    def self.qr_code(user_code)
      r = http(:post, "#{LOGIN_HOST}/v1.0/m/life/home-assistant/qrcode/tokens?#{URI.encode_www_form(clientid: CLIENT_ID, usercode: user_code, schema: SCHEMA)}")
      raise Integrations.auth(Error.new(r["msg"].presence || "A Tuya recusou o código de usuário.")) unless r["success"]

      r.dig("result", "qrcode")
    end

    def self.qr_text(token) = "tuyaSmart--qrLogin?token=#{token}"

    # nil enquanto ninguém escaneou; depois {endpoint, terminal_id, username, token}.
    def self.login_result(token, user_code)
      r = http(:get, "#{LOGIN_HOST}/v1.0/m/life/home-assistant/qrcode/tokens/#{token}?#{URI.encode_www_form(clientid: CLIENT_ID, usercode: user_code)}")
      return unless r["success"]

      res = r["result"] || {}
      { "endpoint" => res["endpoint"], "terminal_id" => res["terminal_id"], "username" => res["username"],
        "token" => { "t" => r["t"], "expire_time" => res["expire_time"], "uid" => res["uid"],
                     "access_token" => res["access_token"], "refresh_token" => res["refresh_token"] } }
    end

    def self.http(method, url, headers: {})
      uri = URI(url)
      req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri, headers.merge("Content-Type" => "application/json"))
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30) { |h| h.request(req) }
      raise Error, "A Tuya respondeu #{res.code}." unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)
    rescue SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError, JSON::ParserError => e
      raise Error, "Sem conexão com a Tuya (#{e.class.name.demodulize})."
    end

    # --- cifra do SDK ---------------------------------------------------------

    def self.secret(rid, hash_key) = OpenSSL::HMAC.hexdigest("SHA256", rid, hash_key)[0, 16]

    def self.sign(hash_key, headers, query)
      text = %w[X-appKey X-requestId X-sid X-time X-token].filter_map { |k| "#{k}=#{headers[k]}" if headers[k].present? }.join("||")
      OpenSSL::HMAC.hexdigest("SHA256", hash_key, text + query.to_s)
    end

    def self.encrypt(text, secret)
      nonce = Array.new(12) { NONCE[SecureRandom.random_number(NONCE.size)] }.join
      c = OpenSSL::Cipher.new("aes-128-gcm").encrypt
      c.key = secret
      c.iv = nonce
      Base64.strict_encode64(nonce) + Base64.strict_encode64(c.update(text) + c.final + c.auth_tag)
    end

    def self.decrypt(data, secret)
      raw = Base64.decode64(data)
      c = OpenSSL::Cipher.new("aes-128-gcm").decrypt
      c.key = secret
      c.iv = raw[0, 12]
      c.auth_tag = raw[-16..]
      c.auth_data = ""
      (c.update(raw[12...-16]) + c.final).force_encoding("UTF-8")
    end

    # --- conta logada -----------------------------------------------------------

    def initialize(integration)
      @integration = integration
      @s = integration.secrets
      raise Integrations.auth(Error.new("Conta Tuya sem login: escaneie o QR code de novo.")) if @s.dig("token", "refresh_token").blank? || @s["endpoint"].blank?
    end

    def get(path, params = nil)
      refresh! if expired? && !@refreshing
      rid = SecureRandom.uuid
      hash_key = Digest::MD5.hexdigest(rid + token["refresh_token"].to_s)
      secret = self.class.secret(rid, hash_key)
      query = params.present? ? self.class.encrypt(params.to_json, secret) : ""
      headers = { "X-appKey" => CLIENT_ID, "X-requestId" => rid, "X-sid" => "", "X-time" => (Time.now.to_f * 1000).to_i.to_s }
      headers["X-token"] = token["access_token"] if token["access_token"].present?
      headers["X-sign"] = self.class.sign(hash_key, headers, query)
      url = "#{@s['endpoint']}#{path}#{"?#{URI.encode_www_form(encdata: query)}" if query.present?}"
      body = self.class.http(:get, url, headers: headers)
      raise Error, "Tuya: #{body['msg'] || body['code']}" unless body["success"]

      result = body["result"]
      result = JSON.parse(self.class.decrypt(result, secret)) if result.is_a?(String) && result.present?
      result
    end

    # Lista de aparelhos de todas as casas da conta, no formato do inventário.
    def inventory
      homes = Array(get("/v1.0/m/life/users/homes"))
      homes.flat_map { |h| Array(get("/v1.0/m/life/ha/home/devices", { "homeId" => h["ownerId"].to_s })) }
           .uniq { |d| d["id"] }.map { |d| entry(d) }
    end

    def entry(d)
      relations = Array(get("/v1.0/m/life/devices/#{d['id']}/status")&.dig("dpStatusRelationDTOS"))
      writable = Array(get("/v1.1/m/life/#{d['id']}/specifications")&.dig("functions")).map { |f| f["code"] }
      room = (get("/v1.0/m/thing/ha/#{d['id']}/room") rescue nil)&.dig("name")
      { "id" => d["id"], "kind" => "tuya_local", "name" => d["name"].to_s.squish.presence || d["id"], "manufacturer" => "Tuya",
        "model" => d["product_name"], "category" => MAP["categories"][d["category"]] || d["category"], "room" => room, "online" => d["online"] == true,
        "sub" => d["sub"] == true, "secret" => d["local_key"], "address" => { "version" => "3.3" },
        "points" => self.class.points(d["name"].to_s, relations, writable) }
    end

    # Mapa de dps da nuvem → pontos. Interruptor e lâmpada passam pela mesma
    # tradução da importação do LocalTuya; o resto vai pelo tipo do dp.
    def self.points(device_name, relations, writable)
      by_code = relations.index_by { |r| r["statusCode"].to_s }
      desc = ->(code) { by_code[code] ? (JSON.parse(by_code[code]["valueDesc"].presence || "{}") rescue {}) : {} }
      dp = ->(code) { by_code.dig(code, "dpId") }
      used = []
      specs = []

      lights = by_code.keys.grep(/\Aswitch_led(_\d+)?\z/).sort
      lights.each do |code|
        n = code[/_(\d+)\z/, 1]
        bright = [ "bright_value#{"_#{n}" if n}", "bright_value_v2#{"_#{n}" if n}" ].find { |c| by_code[c] }
        d = desc.call(bright)
        used.push(code, bright)
        specs += Tuya::Import.specs_for("platform" => "light", "id" => dp.call(code), "device_name" => device_name,
                                        "friendly_name" => (lights.size > 1 ? "Luz #{n}" : "Luz"), "brightness" => bright && dp.call(bright),
                                        "brightness_upper" => d["max"], "brightness_lower" => d["min"])
      end

      switches = by_code.keys.grep(/\Aswitch(_\d+|_usb\d+)?\z/).sort
      switches.each_with_index do |code, i|
        n = code[/(\d+)\z/, 1]
        name = switches.size == 1 ? "Liga/desliga" : (code.include?("usb") ? "USB #{n}" : "Interruptor #{n}")
        e = { "platform" => "switch", "id" => dp.call(code), "friendly_name" => name, "device_name" => device_name }
        if i.zero? # medição da tomada vai junto do primeiro
          { "current" => "cur_current", "current_consumption" => "cur_power", "voltage" => "cur_voltage" }.each do |attr, c|
            next unless by_code[c]

            d = desc.call(c)
            e[attr] = dp.call(c)
            e["#{attr}_scale"] = (10**-d["scale"].to_i).to_d * (d["unit"].to_s == "mA" ? "0.001".to_d : 1)
            used << c
          end
        end
        used << code
        specs += Tuya::Import.specs_for(e)
      end

      by_code.except(*used.compact).each do |code, r|
        next if code.match?(SKIP)

        spec = generic(code, r, desc.call(code), writable.include?(code))
        specs << spec if spec
      end
      specs.uniq { |s| s[:address]["dps"] }.map { |s| s.transform_keys(&:to_s).compact }
    end

    def self.generic(code, r, d, writable)
      known = MAP["codes"][code] || {}
      base = { name: known["name"] || code.humanize, address: { "dps" => r["dpId"].to_s } }
      sc = (10**-d["scale"].to_i).to_d
      case r["valueType"]
      when "Boolean"
        return base.merge(capability: "onoff") if writable
        return base.merge(capability: known["capability"], device_class: known["device_class"]) if known["capability"]

        base.merge(capability: "problem") if code.match?(PROBLEM)
      when "Integer", "Value"
        if writable
          base.merge(capability: "setpoint", scale: sc, unit: d["unit"].presence, min: d["min"] && d["min"] * sc, max: d["max"] && d["max"] * sc)
        else
          base.merge(capability: "measure", scale: sc, unit: known["unit"] || d["unit"].presence, device_class: known["device_class"], state_class: "measurement")
        end
      when "Enum"
        options = Array(d["range"]).map(&:to_s)
        base.merge(capability: "enum", options: options, writable: writable) if options.any?
      end
    end

    private

    def token = @s["token"] || {}

    def expired?
      expires = token["t"].to_i + (token["expire_time"].to_i * 1000)
      expires - 60_000 <= (Time.now.to_f * 1000).to_i
    end

    # Renova o access token pelo refresh token (como o SDK) e grava.
    def refresh!
      @refreshing = true
      r = get("/v1.0/m/token/#{token['refresh_token']}")
      @s["token"] = { "t" => (Time.now.to_f * 1000).to_i, "expire_time" => r["expireTime"], "uid" => r["uid"],
                      "access_token" => r["accessToken"], "refresh_token" => r["refreshToken"] }
      @integration.merge_secrets!("token" => @s["token"])
    ensure
      @refreshing = false
    end
  end
end
