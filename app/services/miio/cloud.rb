require "net/http"

module Miio
  # Conta Xiaomi (Mi Home) só para DESCOBRIR os aparelhos: did, modelo, IP,
  # cômodo e o token miIO de cada um. O controle continua local pelo
  # `xiaomi_miot`. É um login próprio (o mesmo do Xiaomi-cloud-tokens-extractor):
  # nunca usa nem renova o OAuth do `xiaomi_home` do HA.
  #
  # Login por usuário e senha (pode pedir captcha: a imagem vai para a tela)
  # ou por QR code no app Mi Home (é o caminho quando a Xiaomi pede
  # verificação em duas etapas). Estado do login nas credenciais cifradas da
  # integração: username, password, region, device_id, cookies, lp (QR em
  # andamento), captcha (imagem), user_id, ssecurity, service_token.
  class Cloud
    class Error < Integrations::Error; end

    ACCOUNT = "https://account.xiaomi.com".freeze
    STS = "https://sts.api.io.mi.com/sts".freeze
    QS = "%3Fsid%3Dxiaomiio%26_json%3Dtrue".freeze
    REGIONS = { "" => "Procurar em todas", "cn" => "China", "de" => "Europa", "us" => "Estados Unidos", "ru" => "Rússia",
                "tw" => "Taiwan", "sg" => "Singapura", "in" => "Índia", "i2" => "Índia (i2)" }.freeze
    QR_EXPIRED = "QR expirou, gere outro.".freeze
    AGENT ="Android-7.1.1-1.0.0-ONEPLUS A3010-136-ABCDEFGHIJKLM APP/xiaomi.smarthome APPV/62830".freeze

    def initialize(integration)
      @integration = integration
      @s = integration.secrets
      @s["device_id"] ||= Array.new(6) { ("a".."z").to_a.sample }.join
      @s["cookies"] ||= {}
    end

    def logged_in? = @s["service_token"].present? && @s["ssecurity"].present?

    # :ok, :captcha (imagem gravada em `captcha`) ou :two_factor. Senha errada = Error.
    def login(captcha: nil)
      jar.merge!("sdkVersion" => "accountsdk-18.8.15", "deviceId" => @s["device_id"])
      first = json(request(:get, "#{ACCOUNT}/pass/serviceLogin?sid=xiaomiio&_json=true", cookies: { "userId" => @s["username"] }))
      return finish(first) if first["ssecurity"].present? && first["location"].present?

      fields = { sid: "xiaomiio", hash: Digest::MD5.hexdigest(@s["password"].to_s).upcase, callback: STS, qs: QS,
                 user: @s["username"], _sign: first["_sign"], _json: "true" }
      fields[:captCode] = captcha if captcha.present?
      second = json(request(:post, "#{ACCOUNT}/pass/serviceLoginAuth2?#{URI.encode_www_form(fields)}"))
      return finish(second) if second["ssecurity"].to_s.size > 4

      if second["captchaUrl"].present?
        url = second["captchaUrl"].start_with?("/") ? ACCOUNT + second["captchaUrl"] : second["captchaUrl"]
        save!("captcha" => Base64.strict_encode64(request(:get, url).body))
        return :captcha
      end
      return save!("captcha" => nil) && :two_factor if second["notificationUrl"].present?

      raise Error, "Usuário ou senha da Xiaomi não conferem."
    end

    # QR para o app Mi Home: devolve a imagem (PNG) e guarda o endereço de espera.
    def qr_start
      params = { _qrsize: "360", qs: QS, callback: STS, _hasLogo: "false", sid: "xiaomiio", serviceParam: "", _locale: "pt_BR",
                 _dc: (Time.now.to_f * 1000).to_i }
      r = json(request(:get, "#{ACCOUNT}/longPolling/loginUrl?#{URI.encode_www_form(params)}"))
      raise Error, "A Xiaomi não gerou o QR code." if r["qr"].blank? || r["lp"].blank?

      png = request(:get, r["qr"]).body
      save!("lp" => r["lp"], "qr_until" => Time.now.to_i + r["timeout"].to_i.clamp(60, 600), "qr_error" => nil)
      XiaomiQrLoginJob.perform_later(@integration.id)
      png
    end

    # Espera o app confirmar o QR (no worker, pelo XiaomiQrLoginJob). O `lp`
    # vale UMA requisição: largar por timeout e repetir dá 403. Por isso é uma
    # só, longa, até o QR vencer. :ok, ou Error QR_EXPIRED.
    def qr_wait
      lp = @s["lp"] or raise Error, QR_EXPIRED
      res = request(:get, lp, timeout: [ @s["qr_until"].to_i - Time.now.to_i, 1 ].max + 15)
      j = res.is_a?(Net::HTTPSuccess) ? json(res) : {}
      raise Error, QR_EXPIRED if j["location"].blank? || j["ssecurity"].blank?

      finish(j)
    rescue Net::ReadTimeout
      raise Error, QR_EXPIRED
    end

    # Para a tela (a cada 3 s, só lê o estado): true quando entrou, false
    # esperando; Error quando o QR venceu ou falhou.
    def qr_done?
      raise Error, @s["qr_error"] if @s["qr_error"].present?
      return logged_in? if @s["lp"].blank?
      raise Error, QR_EXPIRED if Time.now.to_i > @s["qr_until"].to_i + 60 # worker caiu no meio da espera

      false
    end

    # O QR `lp` não entrou: registra para a tela, se ainda for o QR atual.
    def qr_failed!(lp, message)
      save!("lp" => nil, "qr_error" => message) if @s["lp"] == lp
    end

    # Aparelhos de todas as casas (próprias e compartilhadas), no formato do inventário.
    def inventory
      raise Error, "Conta Xiaomi sem login: entre de novo." unless logged_in?

      regions = @s["region"].present? ? [ @s["region"] ] : REGIONS.keys.compact_blank
      regions.flat_map { |r| devices_in(r) }.uniq { |e| e["id"] }
    end

    def devices_in(region)
      homes = Array(api(region, "/v2/homeroom/gethome", { fg: true, fetch_share: true, fetch_share_dev: true, limit: 300, app_ver: 7 }).dig("result", "homelist"))
      rooms = homes.flat_map { |h| Array(h["roomlist"]).flat_map { |rm| Array(rm["dids"]).map { |did| [ did.to_s, rm["name"] ] } } }.to_h
      shared = Array(api(region, "/v2/user/get_device_cnt", { fetch_own: true, fetch_share: true }).dig("result", "share", "share_family"))
      list = homes.map { |h| [ h["id"], @s["user_id"] ] } + shared.map { |h| [ h["home_id"], h["home_owner"] ] }
      devices = list.flat_map do |home_id, owner|
        Array(api(region, "/v2/home/home_device_list", { home_owner: owner.to_i, home_id: home_id.to_i, limit: 200, get_split_device: true,
                                                          support_smart_home: true }).dig("result", "device_info"))
      end
      devices.select { |d| d["token"].to_s.match?(/\A\h{32}\z/) && d["localip"].present? }.map { |d| entry(d, rooms[d["did"].to_s]) }
    end

    def entry(d, room)
      { "id" => d["did"].to_s, "kind" => "xiaomi_miot", "name" => d["name"].to_s.squish.presence || d["model"], "manufacturer" => "Xiaomi",
        "model" => d["model"], "category" => d["model"].to_s.split(".")[1], "room" => room, "online" => d["isOnline"] == true,
        "secret" => d["token"], "address" => { "host" => d["localip"], "model" => d["model"] },
        "poll_s" => (Spec.vacuum?(d["model"]) ? 60 : nil), "points" => Spec.points(d["model"]) }
    end

    # Chamada cifrada (RC4) da API do app, como o Mi Home faz hoje.
    def api(region, path, data)
      url = "https://#{"#{region}." unless region == 'cn'}api.io.mi.com/app#{path}"
      nonce = Base64.strict_encode64(SecureRandom.random_bytes(8) + [ (Time.now.to_i / 60) ].pack("N"))
      signed = Base64.strict_encode64(Digest::SHA256.digest(Base64.decode64(@s["ssecurity"]) + Base64.decode64(nonce)))
      params = { "data" => data.to_json }
      params["rc4_hash__"] = self.class.signature(path, signed, params)
      params = params.transform_values { |v| Base64.strict_encode64(self.class.rc4(Base64.decode64(signed), v)) }
      params.merge!("signature" => self.class.signature(path, signed, params), "ssecurity" => @s["ssecurity"], "_nonce" => nonce)
      cookies = { "userId" => @s["user_id"].to_s, "yetAnotherServiceToken" => @s["service_token"], "serviceToken" => @s["service_token"],
                  "locale" => "pt_BR", "timezone" => "GMT-03:00", "is_daylight" => "0", "dst_offset" => "0", "channel" => "MI_APP_STORE" }
      res = request(:post, "#{url}?#{URI.encode_www_form(params)}", cookies: cookies, store: false,
                           headers: { "x-xiaomi-protocal-flag-cli" => "PROTOCAL-HTTP2", "MIOT-ENCRYPT-ALGORITHM" => "ENCRYPT-RC4" })
      if res.code.to_i.in?([ 401, 403 ])
        save!("service_token" => nil)
        raise Error, "A sessão da Xiaomi expirou: entre de novo."
      end
      raise Error, "A Xiaomi respondeu #{res.code}." unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(self.class.rc4(Base64.decode64(signed), Base64.decode64(res.body)).force_encoding("UTF-8"))
    end

    def self.signature(path, signed_nonce, params)
      text = [ "POST", path, *params.map { |k, v| "#{k}=#{v}" }, signed_nonce ].join("&")
      Base64.strict_encode64(Digest::SHA1.digest(text))
    end

    # RC4 com os 1024 primeiros bytes descartados (o OpenSSL 3 não traz RC4).
    def self.rc4(key, data)
      s = (0..255).to_a
      j = 0
      256.times do |i|
        j = (j + s[i] + key.getbyte(i % key.bytesize)) & 255
        s[i], s[j] = s[j], s[i]
      end
      i = j = 0
      out = (("\0" * 1024).b + data.b).bytes.map do |b|
        i = (i + 1) & 255
        j = (j + s[i]) & 255
        s[i], s[j] = s[j], s[i]
        b ^ s[(s[i] + s[j]) & 255]
      end
      out[1024..].pack("C*")
    end

    private

    def jar = @s["cookies"]

    def finish(j)
      res = request(:get, j["location"])
      token = jar["serviceToken"]
      raise Error, "A Xiaomi não entregou a sessão (serviceToken)." if token.blank? || !res.is_a?(Net::HTTPSuccess)

      save!("user_id" => j["userId"].to_s, "ssecurity" => j["ssecurity"], "service_token" => token, "lp" => nil, "captcha" => nil)
      :ok
    end

    def save!(values)
      @s.merge!(values)
      @integration.update!(credentials: @s.compact.to_json)
      true
    end

    def json(res) = JSON.parse(res.body.to_s.delete_prefix("&&&START&&&").presence || "{}")

    def request(method, url, cookies: {}, headers: {}, store: true, timeout: 20)
      uri = URI(url)
      req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri, { "User-Agent" => AGENT, "Accept-Encoding" => "identity",
                                                                              "Content-Type" => "application/x-www-form-urlencoded" }.merge(headers))
      all = (store ? jar : {}).merge(cookies).compact_blank
      req["Cookie"] = all.map { |k, v| "#{k}=#{v}" }.join("; ") if all.any?
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: timeout) { |h| h.request(req) }
      Array(res.get_fields("set-cookie")).each { |c| k, v = c.split(";").first.split("=", 2); jar[k.strip] = v.to_s if store && v.present? }
      res
    rescue Net::ReadTimeout
      raise
    rescue SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError, JSON::ParserError => e
      raise Error, "Sem conexão com a Xiaomi (#{e.class.name.demodulize})."
    end
  end
end
