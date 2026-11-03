require "socket"
require "openssl"

module Integrations
  # TP-Link Kasa e Tapo (catalogo). Kasa: protocolo local antigo (TCP 9999,
  # JSON cifrado por XOR com chave 171): tomadas, filtros de linha (cada
  # tomada vira um ponto), interruptores, dimmers, lâmpadas e medição de
  # energia. Tapo (e Kasa novos): KLAP v2 pelo HTTP 80 com o e-mail e a senha
  # da conta TP-Link (o aparelho confere o hash; nada vai para a nuvem).
  class TplinkPlugin < SchemaPlugin
    describe key: "tplink", title: "TP-Link Kasa / Tapo", icon: "power",
             description: "Tomadas, filtros de linha, interruptores e lâmpadas TP-Link Kasa e Tapo na rede de casa: liga, brilho e consumo de energia."
    texts "pt-BR" => { fields: { protocol: "Linha do aparelho" }, options: { protocol: { kasa: "Kasa (antigo, sem senha)", tapo: "Tapo / Kasa novo (conta TP-Link)" } },
                       note: "Tapo pede o e-mail e a senha da conta TP-Link: o aparelho confere o hash na rede de casa, nada vai para a nuvem.",
                       refused: "O aparelho recusou o login: confira o e-mail e a senha da conta TP-Link." },
          en: { title: "TP-Link Kasa / Tapo", description: "TP-Link Kasa and Tapo plugs, power strips, switches and bulbs on your home network: power, brightness and energy use.",
                fields: { protocol: "Device line" }, options: { protocol: { kasa: "Kasa (legacy, no password)", tapo: "Tapo / new Kasa (TP-Link account)" } },
                note: "Tapo needs the TP-Link account e-mail and password: the device checks the hash on your home network, nothing goes to the cloud.",
                refused: "The device refused the login: check the TP-Link account e-mail and password." },
          es: { title: "TP-Link Kasa / Tapo", description: "Enchufes, regletas, interruptores y bombillas TP-Link Kasa y Tapo en la red de casa: encendido, brillo y consumo de energía.",
                fields: { protocol: "Línea del aparato" }, options: { protocol: { kasa: "Kasa (antiguo, sin contraseña)", tapo: "Tapo / Kasa nuevo (cuenta TP-Link)" } },
                note: "Tapo pide el e-mail y la contraseña de la cuenta TP-Link: el aparato verifica el hash en la red de casa, nada va a la nube.",
                refused: "El aparato rechazó el inicio de sesión: revisa el e-mail y la contraseña de la cuenta TP-Link." }
    field :host, required: true
    field :protocol, :select, options: %w[kasa tapo], default: "kasa"
    field :username
    field :password, secret: true
    dhcp({ hostname: "hs*" }, { hostname: "kp*" }, { hostname: "tapo*" }, { hostname: "p1*" }, { mac: "1C3BF3" }, { mac: "50C7BF" }, { mac: "5C628B" })

    KASA_PORT = 9999

    class << self
      # --- Kasa (XOR) ---
      def xor(bytes, decrypt: false)
        key = 171
        bytes.bytes.map { |b| (c = key ^ b).tap { key = decrypt ? b : c } }.pack("C*")
      end

      def kasa(host, req, timeout: 4)
        Socket.tcp(host, KASA_PORT, connect_timeout: timeout) do |s|
          data = xor(req.to_json)
          s.write([ data.bytesize ].pack("N") + data)
          len = read_n(s, 4, timeout).unpack1("N")
          JSON.parse(xor(read_n(s, len, timeout), decrypt: true))
        end
      rescue *LanPlugin::NET_ERRORS => e
        raise Integrations::Error, "#{host}: #{e.class.name.demodulize}"
      end

      def read_n(sock, n, timeout)
        out = +"".b
        while out.bytesize < n
          raise Integrations::Error, "#{n} bytes?" unless sock.wait_readable(timeout)

          chunk = sock.read_nonblock(n - out.bytesize, exception: false) or raise(Integrations::Error, "EOF")
          out << chunk unless chunk.is_a?(Symbol)
        end
        out
      end

      # --- Tapo (KLAP v2) ---
      def sha256(*parts) = OpenSSL::Digest::SHA256.digest(parts.join)
      def auth_hash(user, pass) = sha256(OpenSSL::Digest::SHA1.digest(user.to_s), OpenSSL::Digest::SHA1.digest(pass.to_s))
      def octet(extra = {}) = { "Content-Type" => "application/octet-stream" }.merge(extra)

      # Sessão: {base, cookie, key, iv, seq, sig} (derivados das sementes e do hash da conta).
      def klap_session(host, user, pass)
        base = "http://#{host}/app"
        local = SecureRandom.random_bytes(16)
        auth = auth_hash(user, pass)
        cookie = nil
        body = LanHttp.call(:post, "#{base}/handshake1", body: local, headers: octet, raw: true) { |res| cookie = res["set-cookie"].to_s[/TP_SESSIONID=[^;]+/] }.b
        remote = body.byteslice(0, 16)
        raise Integrations.auth(Integrations::Error.new(text(:refused))) unless body.byteslice(16, 32) == sha256(local, remote, auth)

        LanHttp.call(:post, "#{base}/handshake2", body: sha256(remote, local, auth), headers: octet("Cookie" => cookie.to_s), raw: true)
        ivseq = sha256("iv", local, remote, auth)
        { base: base, cookie: cookie.to_s, key: sha256("lsk", local, remote, auth).byteslice(0, 16), iv: ivseq.byteslice(0, 12),
          seq: ivseq.byteslice(-4, 4).unpack1("l>"), sig: sha256("ldk", local, remote, auth).byteslice(0, 28) }
      end

      def klap_cipher(s, seq, mode)
        c = OpenSSL::Cipher.new("aes-128-cbc").public_send(mode)
        c.key = s[:key]
        c.iv = s[:iv] + [ seq ].pack("l>")
        c
      end

      def tapo(host, user, pass, method, params = nil)
        s = klap_session(host, user, pass)
        seq = s[:seq] + 1
        c = klap_cipher(s, seq, :encrypt)
        enc = c.update({ method: method, params: params }.compact.to_json) + c.final
        raw = LanHttp.call(:post, "#{s[:base]}/request?seq=#{seq}", body: sha256(s[:sig], [ seq ].pack("l>"), enc) + enc,
                                                                    headers: octet("Cookie" => s[:cookie]), raw: true).b
        d = klap_cipher(s, seq, :decrypt)
        r = JSON.parse(d.update(raw.byteslice(32..)) + d.final)
        raise Integrations::Error, "Tapo: #{r['error_code']}" unless r["error_code"].to_i.zero?

        r["result"].to_h
      rescue OpenSSL::Cipher::CipherError, JSON::ParserError => e
        raise Integrations::Error, "Tapo: #{e.class.name.demodulize}"
      end

      def tapo_call(integration, host, method, params = nil) = tapo(host, conf(integration, :username), conf(integration, :password), method, params)

      def energy_points = [ point("power", unit: "W", device_class: "power", state_class: "measurement"),
                            point("energy", unit: "kWh", device_class: "energy", state_class: "total_increasing") ]

      def entries(integration)
        host = conf(integration, :host)
        conf(integration, :protocol) == "tapo" ? tapo_entries(integration, host) : kasa_entries(host)
      end

      def kasa_entries(host)
        info = kasa(host, { system: { get_sysinfo: {} } }).dig("system", "get_sysinfo").to_h
        children = Array(info["children"])
        emeter = info["feature"].to_s.include?("ENE")
        outlets = if children.any? then children.map { |c| point("relay:#{c['id']}", "onoff", name: c["alias"].presence || text("points.switch")) }
        elsif info.key?("light_state")
                    [ point("light_on", "onoff", name: text("points.light"), icon: "light-bulb"), point("light_bri", "dimmer", name: text("points.brightness"), min: 1, max: 100) ]
        else [ point("relay", "onoff", name: text("points.switch")), (point("brightness", "dimmer", min: 1, max: 100) if info.key?("brightness")) ]
        end
        [ entry(id: "tplink:#{info['mac'] || info['mic_mac'] || host}", name: info["alias"].presence || info["model"].to_s, model: info["model"],
                address: { "host" => host, "protocol" => "kasa" }, poll_s: 30, points: outlets + (emeter ? energy_points : [])) ]
      end

      def tapo_entries(integration, host)
        info = tapo_call(integration, host, "get_device_info")
        name = Base64.decode64(info["nickname"].to_s).force_encoding("UTF-8").presence || info["model"].to_s
        energy = begin
          tapo_call(integration, host, "get_energy_usage").key?("current_power")
        rescue Integrations::Error
          false
        end
        pts = [ point("device_on", "onoff", name: text("points.switch")), (point("brightness", "dimmer", min: 1, max: 100) if info.key?("brightness")) ]
        [ entry(id: "tplink:#{info['mac'] || host}", name: name, model: info["model"], address: { "host" => host, "protocol" => "tapo" }, poll_s: 30,
                points: pts + (energy ? energy_points : [])) ]
      end

      def read(device)
        host = device.address["host"]
        energy = device.points.any? { |p| p.address["field"] == "power" }
        device.address["protocol"] == "tapo" ? tapo_read(device.integration, host, energy) : kasa_read(host, energy)
      end

      def kasa_read(host, energy)
        req = { system: { get_sysinfo: {} } }
        req[:emeter] = { get_realtime: {} } if energy
        r = kasa(host, req)
        info = r.dig("system", "get_sysinfo").to_h
        ls = info["light_state"].to_h
        e = r.dig("emeter", "get_realtime").to_h
        out = { "relay" => (info["relay_state"] == 1 if info.key?("relay_state")), "brightness" => info["brightness"],
                "light_on" => (ls["on_off"] == 1 if ls.any?), "light_bri" => ls["brightness"] || ls.dig("dft_on_state", "brightness"),
                "power" => (e["power_mw"] ? e["power_mw"] / 1000.0 : e["power"])&.round(1),
                "energy" => (e["total_wh"] ? e["total_wh"] / 1000.0 : e["total"])&.round(3) }
        Array(info["children"]).each { |c| out["relay:#{c['id']}"] = c["state"] == 1 }
        out
      end

      def tapo_read(integration, host, energy)
        info = tapo_call(integration, host, "get_device_info")
        out = { "device_on" => info["device_on"], "brightness" => info["brightness"] }
        return out unless energy

        e = tapo_call(integration, host, "get_energy_usage")
        out.merge("power" => (e["current_power"].to_f / 1000).round(1), "energy" => (e["month_energy"].to_f / 1000).round(3))
      end

      def write(point, value)
        d = point.device
        host = d.address["host"]
        f = point.address["field"]
        if d.address["protocol"] == "tapo"
          return tapo_call(d.integration, host, "set_device_info", f == "brightness" ? { device_on: true, brightness: value.to_i } : { device_on: value == true })
        end

        state = { set_relay_state: { state: value ? 1 : 0 } }
        req = case f
        when "relay" then { system: state }
        when /\Arelay:(.+)\z/ then { context: { child_ids: [ ::Regexp.last_match(1) ] }, system: state }
        when "brightness" then { "smartlife.iot.dimmer" => { set_brightness: { brightness: value.to_i } } }
        when "light_on" then { "smartlife.iot.smartbulb.lightingservice" => { transition_light_state: { on_off: value ? 1 : 0 } } }
        when "light_bri" then { "smartlife.iot.smartbulb.lightingservice" => { transition_light_state: { on_off: 1, brightness: value.to_i } } }
        end
        kasa(host, req)
      end
    end
  end
end
