require "openssl"
require "rexml/document"

module Integrations
  # FRITZ!Box Smart Home (catalogo): tomadas FRITZ!DECT, termostatos e
  # sensores ligados a um FRITZ!Box, pela interface AHA (`homeautoswitch.lua`)
  # com o login do próprio FRITZ!Box (desafio PBKDF2 ou MD5, `login_sid.lua`).
  class FritzboxPlugin < SchemaPlugin
    describe key: "fritzbox", title: "FRITZ!Box Smart Home", icon: "home",
             description: "Tomadas FRITZ!DECT, termostatos e sensores do FRITZ!Box: liga/desliga, consumo, temperatura e a temperatura alvo do termostato."
    texts "pt-BR" => { points: { setpoint: "Temperatura alvo" }, refused: "O FRITZ!Box recusou o login: confira usuário e senha." },
          en: { title: "FRITZ!Box Smart Home", description: "FRITZ!DECT plugs, thermostats and sensors on a FRITZ!Box: on/off, power use, temperature and the thermostat's target temperature.",
                points: { setpoint: "Target temperature" }, refused: "The FRITZ!Box refused the login: check username and password." },
          es: { title: "FRITZ!Box Smart Home", description: "Enchufes FRITZ!DECT, termostatos y sensores del FRITZ!Box: encendido, consumo, temperatura y la temperatura objetivo del termostato.",
                points: { setpoint: "Temperatura objetivo" }, refused: "El FRITZ!Box rechazó el inicio de sesión: revisa usuario y contraseña." }
    field :host, required: true, default: "fritz.box"
    field :username
    field :password, secret: true, required: true

    class << self
      def tag(xml, name) = xml[%r{<#{name}>([^<]*)</#{name}>}, 1]

      # Resposta ao desafio: "2$iter1$salt1$iter2$salt2" (PBKDF2) ou o antigo MD5 em UTF-16LE.
      def answer(challenge, password)
        if challenge.start_with?("2$")
          _, i1, s1, i2, s2 = challenge.split("$")
          h1 = OpenSSL::KDF.pbkdf2_hmac(password, salt: [ s1 ].pack("H*"), iterations: i1.to_i, length: 32, hash: "sha256")
          h2 = OpenSSL::KDF.pbkdf2_hmac(h1, salt: [ s2 ].pack("H*"), iterations: i2.to_i, length: 32, hash: "sha256")
          "#{s2}$#{h2.unpack1('H*')}"
        else
          "#{challenge}-#{OpenSSL::Digest::MD5.hexdigest("#{challenge}-#{password}".encode('UTF-16LE'))}"
        end
      end

      def sid(integration)
        base = LanHttp.base(conf(integration, :host))
        xml = LanHttp.get("#{base}/login_sid.lua?version=2", raw: true).to_s
        q = { username: conf(integration, :username).to_s, response: answer(tag(xml, "Challenge").to_s, conf(integration, :password).to_s) }
        sid = tag(LanHttp.get("#{base}/login_sid.lua?version=2&#{q.to_query}", raw: true).to_s, "SID").to_s
        raise Integrations.auth(Integrations::Error.new(text(:refused))) if sid.delete("0").empty?

        sid
      end

      def aha(integration, cmd, sid: nil, **params)
        base = LanHttp.base(conf(integration, :host))
        LanHttp.get("#{base}/webservices/homeautoswitch.lua?#{{ switchcmd: cmd, sid: sid || sid(integration), **params }.to_query}", raw: true).to_s
      end

      def devices(integration)
        doc = REXML::Document.new(aha(integration, "getdevicelistinfos"))
        doc.elements.to_a("devicelist/device").map do |d|
          val = ->(path) { d.elements[path]&.text }
          { "ain" => d.attributes["identifier"].to_s.delete(" "), "name" => val.("name"), "model" => d.attributes["productname"], "present" => val.("present") == "1",
            "switch" => (val.("switch/state") == "1" if d.elements["switch"]), "power" => (val.("powermeter/power").to_f / 1000 if d.elements["powermeter"]),
            "energy" => (val.("powermeter/energy").to_f / 1000 if d.elements["powermeter"]),
            "voltage" => (val.("powermeter/voltage").to_f / 1000 if d.elements["powermeter/voltage"]),
            "temperature" => (val.("temperature/celsius").to_f / 10 + val.("temperature/offset").to_f / 10 if d.elements["temperature"]),
            "setpoint" => (raw_temp(val.("hkr/tsoll")) if d.elements["hkr"]), "humidity" => val.("humidity/rel_humidity")&.to_i,
            "battery" => val.("battery")&.to_i }
        end
      end

      # Termostato: meio grau (16 = 8 °C); 253 = desligado, 254 = ligado.
      def raw_temp(v) = (v.to_i.between?(16, 56) ? v.to_i / 2.0 : nil)

      def entries(integration)
        devices(integration).map do |d|
          pts = [ (point("switch", "onoff", icon: "power") unless d["switch"].nil?), (point("power", unit: "W", device_class: "power", state_class: "measurement") if d["power"]),
                  (point("energy", unit: "kWh", device_class: "energy", state_class: "total_increasing") if d["energy"]),
                  (point("temperature", unit: "°C", device_class: "temperature", state_class: "measurement") if d["temperature"]),
                  (point("setpoint", "setpoint", unit: "°C", min: 8, max: 28, step: 0.5) if d["setpoint"]),
                  (point("humidity", unit: "%", device_class: "humidity", state_class: "measurement") if d["humidity"]),
                  (point("battery", unit: "%", device_class: "battery", state_class: "measurement") if d["battery"]) ]
          entry(id: "fritzbox:#{d['ain']}", name: d["name"].presence || d["ain"], manufacturer: "AVM", model: d["model"], online: d["present"],
                address: { "ain" => d["ain"] }, poll_s: 60, points: pts)
        end
      end

      def read(device) = devices(device.integration).find { |d| d["ain"] == device.address["ain"] }.to_h

      def write(point, value)
        i = point.device.integration
        ain = point.device.address["ain"]
        point.address["field"] == "setpoint" ? aha(i, "sethkrtsoll", ain: ain, param: (value.to_f * 2).round) : aha(i, value ? "setswitchon" : "setswitchoff", ain: ain)
      end
    end
  end
end
