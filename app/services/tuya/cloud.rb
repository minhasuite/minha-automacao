require "net/http"

module Tuya
  # Conta Smart Life / Tuya Smart pelo mesmo caminho da integração oficial
  # `tuya` do HA (tuya-device-sharing-sdk): login por QR code no app, sem conta
  # Tuya IoT Core. Como no HA: lista de aparelhos (inclusive os Zigbee atrás do
  # hub, ligados a ele por `via`), estado inicial, comando por código de dp
  # (`commands`, driver `tuya_cloud`) e a credencial do MQTT de tempo real
  # (`mqtt_config`, usada pelo Tuya::CloudListener). Cada login por QR gera um
  # token próprio: o do HA continua valendo.
  #
  # Credenciais da integração (cifradas): user_code, qr (token do QR em
  # andamento), endpoint, terminal_id, token ({t, expire_time, uid,
  # access_token, refresh_token}). Pedido assinado e cifrado (AES-GCM) como no
  # SDK; o access token é renovado sozinho e gravado de volta.
  class Cloud
    class Error < Integrations::Error; end
    # Recusa sem efeito (429/5xx): repetível (Transient), com o Retry-After.
    class Busy < Error
      include Transient::Busy
    end

    LOGIN_HOST = "https://apigw.iotbing.com".freeze
    CLIENT_ID = "HA_3y9q4ak7g4ephrvke".freeze # o mesmo do HA
    SCHEMA = "haauthorize".freeze
    NONCE = "ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678".chars.freeze

    # Códigos que viram ponto (nome, unidade, capacidade): dado em config/device_maps/tuya.yml.
    MAP = YAML.load_file(Rails.root.join("config/device_maps/tuya.yml")).freeze
    SKIP = Regexp.new(MAP["skip"])
    PROBLEM = Regexp.new(MAP["problem"])

    # Mapa com o que os pacotes instalados somam (Pacote 3, DeviceMaps).
    def self.map = DeviceMaps.apply("tuya", MAP)
    # Chaves do mapa que vão para o endereço do ponto (Points::Decode, PointHoldJob, ouvinte).
    ADDRESS_KEYS = %w[decode field match unmatched hold_s push_only accumulate color].freeze
    # Aparelho da nuvem vira `tuya_cloud`; o mesmo device_id já no local como
    # `tuya_local` (LocalTuya importado) casa com ele e continua local.
    DRIVERS = %w[tuya_cloud tuya_local].freeze

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

    # Conexão que nem abriu (OpenTimeout, DNS, recusa) tenta de novo na hora uma
    # vez (Transient.with_retry: nada saiu); o resto, incluindo leitura que
    # estourou depois do envio, sobe como erro (docs/confiabilidade.md).
    def self.http(method, url, headers: {}, body: nil)
      uri = URI(url)
      req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri, headers.merge("Content-Type" => "application/json"))
      req.body = body if body
      res = Transient.with_retry { Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30) { |h| h.request(req) } }
      if Transient::STATUSES.include?(res.code.to_i)
        raise Busy.new("A Tuya respondeu #{res.code}.", status: res.code.to_i, retry_after: Transient.parse_retry_after(res["Retry-After"]))
      end
      raise Error, "A Tuya respondeu #{res.code}." unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)
    rescue SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError, JSON::ParserError => e
      raise Error, "Sem conexão com a Tuya (#{e.class.name.demodulize})."
    end

    # --- cifra do SDK ---------------------------------------------------------

    def self.secret(rid, hash_key) = OpenSSL::HMAC.hexdigest("SHA256", rid, hash_key)[0, 16]

    # `data` = query cifrada seguida do corpo cifrado (os dois entram na assinatura).
    def self.sign(hash_key, headers, data)
      text = %w[X-appKey X-requestId X-sid X-time X-token].filter_map { |k| "#{k}=#{headers[k]}" if headers[k].present? }.join("||")
      OpenSSL::HMAC.hexdigest("SHA256", hash_key, text + data.to_s)
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

    def get(path, params = nil) = request(:get, path, params)
    def post(path, payload) = request(:post, path, nil, payload)

    # Pedido do SDK: query e corpo cifrados ({"encdata": …}) e assinados juntos.
    def request(method, path, params = nil, payload = nil)
      refresh! if expired? && !@refreshing
      rid = SecureRandom.uuid
      hash_key = Digest::MD5.hexdigest(rid + token["refresh_token"].to_s)
      secret = self.class.secret(rid, hash_key)
      query = params.present? ? self.class.encrypt(params.to_json, secret) : ""
      data = payload.present? ? self.class.encrypt(payload.to_json, secret) : ""
      headers = { "X-appKey" => CLIENT_ID, "X-requestId" => rid, "X-sid" => "", "X-time" => (Time.now.to_f * 1000).to_i.to_s }
      headers["X-token"] = token["access_token"] if token["access_token"].present?
      headers["X-sign"] = self.class.sign(hash_key, headers, query + data)
      url = "#{@s['endpoint']}#{path}#{"?#{URI.encode_www_form(encdata: query)}" if query.present?}"
      body = self.class.http(method, url, headers: headers, body: ({ "encdata" => data }.to_json if data.present?))
      raise Error, "Tuya: #{body['msg'] || body['code']}" unless body["success"]

      result = body["result"]
      result = JSON.parse(self.class.decrypt(result, secret)) if result.is_a?(String) && result.present?
      result
    end

    # Aparelhos de todas as casas da conta, como a API devolve (com `status`).
    def devices
      homes = Array(get("/v1.0/m/life/users/homes"))
      homes.flat_map { |h| Array(get("/v1.0/m/life/ha/home/devices", { "homeId" => h["ownerId"].to_s })) }.uniq { |d| d["id"] }
    end

    # Lista de aparelhos no formato do inventário, com o hub de cada sub-dispositivo.
    def inventory
      list = devices
      vias = self.class.vias(list)
      list.map { |d| entry(d).merge("address" => { "via" => vias[d["id"]] }.compact) }
    end

    # Estado atual ({device_id → {online, state}}) com 2 pedidos, sem varrer os dps.
    def states = devices.to_h { |d| [ d["id"], { "online" => d["online"] == true, "state" => self.class.state(d) } ] }

    def self.state(d) = Array(d["status"]).each_with_object({}) { |s, h| h[s["code"].to_s] = s["value"] if s.is_a?(Hash) && s.key?("code") }

    def entry(d)
      relations = Array(get_hash("/v1.0/m/life/devices/#{d['id']}/status")["dpStatusRelationDTOS"])
      writable = Array(get_hash("/v1.1/m/life/#{d['id']}/specifications")["functions"]).map { |f| f["code"] }
      room = (get_hash("/v1.0/m/thing/ha/#{d['id']}/room") rescue {})["name"]
      { "id" => d["id"], "kind" => "tuya_cloud", "match_drivers" => DRIVERS, "name" => d["name"].to_s.squish.presence || d["id"],
        "manufacturer" => "Tuya", "model" => d["product_name"], "category" => self.class.map["categories"][d["category"]] || d["category"], "room" => room,
        "online" => d["online"] == true, "sub" => d["sub"] == true && !self.class.gateway?(d), "secret" => d["local_key"], "poll_s" => 0,
        "state" => self.class.state(d), "points" => (self.class.remote_points(d) + self.class.points(d["name"].to_s, relations, writable) + self.class.stream_points(d)).uniq { |p| p.dig("address", "dps") } }
    end

    # Lote 9: câmera com vídeo pela nuvem (`streams` no mapa) → ponto `stream`
    # sob demanda: o go2rtc recebe o endereço na hora de ver (Drivers::Go2rtc).
    def self.stream_points(d)
      return [] unless Array(map["streams"]).include?(d["category"])

      [ { "name" => "Vídeo", "capability" => "stream", "data_type" => "string", "writable" => false, "history" => "none",
          "address" => { "dps" => "video", "on_demand" => true } } ]
    end

    # Pacote 1: hub IR (`remotes` no mapa) → controle remoto genérico (Remotes), pela rede local.
    def self.remote_points(d)
      r = MAP.dig("remotes", d["category"]) or return []

      [ { "name" => r["name"], "capability" => "remote", "history" => "none", "address" => r.except("name").merge("remote" => "tuya_ir") } ]
    end

    # Endereço RTSP de agora da câmera (o mesmo pedido do HA; vence em minutos).
    def stream_url(device_id) = post("/v1.0/m/ipc/#{device_id}/stream/actions/allocate", { "type" => "rtsp" }).to_h["url"].presence

    def self.gateway?(d) = Array(map["gateways"]).include?(d["category"])

    # Sub-dispositivo → hub. A API de compartilhamento não diz o pai: os
    # filhos do controle IR herdam a chave local dele e os do hub Zigbee
    # dividem uma chave só. Mesma chave de um hub = esse hub; senão, o único
    # hub sem filho na própria chave. Sem como decidir, fica sem `via`.
    def self.vias(list)
      hubs = list.select { |d| gateway?(d) }
      subs = list.select { |d| d["sub"] == true && !gateway?(d) }
      keyed = subs.filter_map { |s| s["local_key"].presence }.to_set
      lonely = hubs.reject { |h| keyed.include?(h["local_key"]) }
      subs.each_with_object({}) do |s, out|
        hub = hubs.find { |h| h["local_key"].present? && h["local_key"] == s["local_key"] } || (lonely.first if lonely.one?)
        out[s["id"]] = hub["id"] if hub
      end
    end

    # Comando por código de dp, como o HA ({code, value} já no valor bruto).
    def commands(device_id, list) = post("/v1.1/m/thing/#{device_id}/commands", { "commands" => list })

    # Credencial do MQTT de tempo real ({url, clientId, username, password,
    # expireTime, topic: {devId: {sub}}}); linkId próprio por conexão.
    def mqtt_config = post("/v1.0/m/life/ha/access/config", { "linkId" => "minha-automacao.#{SecureRandom.uuid}" })

    # Mapa de dps da nuvem → pontos. Interruptor e lâmpada passam pela mesma
    # tradução da importação do LocalTuya; o resto vai pelo tipo do dp. Todo
    # ponto leva o código do dp no endereço (comando e tempo real da nuvem).
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
      code_of = relations.to_h { |r| [ r["dpId"].to_s, r["statusCode"].to_s ] }
      specs.uniq { |s| s[:address]["dps"] }.map do |s|
        address = s[:address].merge("code" => code_of[s[:address]["dps"]])
        address["color"] = color_siblings(address["color"], dp) if address["color"]
        s.merge(address: address).transform_keys(&:to_s).compact
      end
    end

    # Cor (Lote 8): o código do dp irmão (temperatura, modo) ganha o dpId; o que o aparelho não tem sai.
    def self.color_siblings(conf, dp)
      conf.filter_map do |k, h|
        next [ k, h ] unless h.is_a?(Hash) && h["code"]

        (id = dp.call(h["code"])) && [ k, h.merge("dps" => id.to_s) ]
      end.to_h
    end

    # Código do mapa (`codes`) ou de uma família numerada (`patterns`; %{1} = o número).
    def self.known(code)
      return map["codes"][code] if map["codes"][code]

      Array(MAP["patterns"]).each do |p|
        m = code.match(Regexp.new(p["match"])) or next
        return p.except("match").merge("name" => p["name"].to_s.gsub(/%\{(\d)\}/) { m[Regexp.last_match(1).to_i] })
      end
      nil
    end

    def self.generic(code, r, d, writable)
      known = known(code) || {}
      writable &&= !known["read_only"]
      base = { name: known["name"] || code.humanize, address: { "dps" => r["dpId"].to_s }.merge(known.slice(*ADDRESS_KEYS)), risk: known["risk"] }
      # Valor empacotado (movimento da câmera, enum → sim/não): o mapa diz como ler.
      return base.merge(capability: known["capability"], device_class: known["device_class"], writable: false) if known["decode"]
      # Evento (botão, campainha): dispara a cada empurrão; as opções do enum vão para o editor.
      return base.merge(capability: "event", options: Array(d["range"]).map(&:to_s).presence) if known["capability"] == "event"
      return base.merge(capability: "color", writable: writable) if known["color"] # Lote 8: irmãos resolvidos em `points`

      sc = (10**-d["scale"].to_i).to_d
      case r["valueType"]
      when "Boolean"
        return base.merge(capability: "onoff") if writable
        return base.merge(capability: known["capability"], device_class: known["device_class"], writable: false) if known["capability"]

        base.merge(capability: "problem") if code.match?(PROBLEM)
      when "Integer", "Value"
        if writable
          base.merge(capability: "setpoint", scale: sc, unit: d["unit"].presence, min: d["min"] && d["min"] * sc, max: d["max"] && d["max"] * sc)
        else
          base.merge(capability: "measure", scale: sc, unit: known["unit"] || d["unit"].presence, device_class: known["device_class"],
                     state_class: known["state_class"] || "measurement")
        end
      when "Enum"
        options = Array(d["range"]).map(&:to_s)
        base.merge(capability: "enum", options: options, writable: writable) if options.any?
      end
    end

    private

    # Aparelho virtual (controle IR) responde texto vazio no lugar do objeto.
    def get_hash(path) = get(path).then { |r| r.is_a?(Hash) ? r : {} }

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
