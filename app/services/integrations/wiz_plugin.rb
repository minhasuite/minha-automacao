require "socket"

module Integrations
  # WiZ (catalogo): lâmpadas e tomadas WiZ pela API local (UDP 38899, JSON):
  # `getPilot`/`setPilot` e `getSystemConfig`. Sem nuvem.
  class WizPlugin < SchemaPlugin
    describe key: "wiz", title: "WiZ", icon: "light-bulb",
             description: "Lâmpadas, fitas e tomadas WiZ (Philips, Ledvance e outras) na rede de casa: liga, brilho, cor e branco, sem nuvem."
    texts en: { title: "WiZ", description: "WiZ bulbs, strips and plugs (Philips, Ledvance and others) on your home network: power, brightness, color and white, no cloud.",
                no_answer: "The WiZ device didn't answer." },
          es: { title: "WiZ", description: "Bombillas, tiras y enchufes WiZ (Philips, Ledvance y otros) en la red de casa: encendido, brillo, color y blanco, sin nube.",
                no_answer: "El aparato WiZ no respondió." },
          "pt-BR" => { no_answer: "O aparelho WiZ não respondeu." }
    field :host, required: true
    dhcp({ hostname: "wiz_*" }, { mac: "A8BB50" }, { mac: "D8A011" }, { mac: "444F8E" }, { mac: "6C2990" })
    PORT = 38_899

    def self.call(host, method, params = {}, timeout: 2)
      sock = UDPSocket.new
      sock.send({ method: method, params: params }.to_json, 0, host, PORT)
      raise Integrations::Error, text(:no_answer) unless sock.wait_readable(timeout)

      JSON.parse(sock.recvfrom(2048).first)["result"].to_h
    rescue *LanPlugin::NET_ERRORS => e
      raise Integrations::Error, "#{text(:no_answer)} (#{e.class.name.demodulize})"
    ensure
      sock&.close
    end

    def self.entries(integration)
      host = conf(integration, :host)
      sys = call(host, "getSystemConfig")
      light = !sys["moduleName"].to_s.match?(/SOCKET|PLUG/i)
      [ entry(id: "wiz:#{sys['mac'].presence || host}", name: "WiZ #{sys['moduleName']}".strip, model: sys["moduleName"], address: { "host" => host }, poll_s: 30,
              points: [ point("state", "onoff", name: text(light ? "points.light" : "points.switch"), icon: light ? "light-bulb" : "power"),
                        (point("dimming", "dimmer", name: text("points.brightness"), min: 10, max: 100) if light),
                        (point("color", "color") if light) ]) ]
    end

    def self.read(device)
      r = call(device.address["host"], "getPilot")
      color = if r["temp"].to_i.positive? then { "mode" => "temp", "kelvin" => r["temp"].to_i }
      elsif r.key?("r") then Points::Color.from_rgb([ r["r"], r["g"], r["b"] ].map(&:to_i))
      end
      { "state" => r["state"] == true, "dimming" => r["dimming"], "color" => color }
    end

    def self.write(point, value)
      params = case point.address["field"]
      when "state" then { state: value == true }
      when "dimming" then { state: true, dimming: value.to_i.clamp(10, 100) }
      when "color"
                 value["mode"] == "temp" ? { state: true, temp: value["kelvin"].to_i } : Points::Color.rgb(value.merge("v" => 100)).then { |r, g, b| { state: true, r: r, g: g, b: b } }
      end
      call(point.device.address["host"], "setPilot", params)
    end
  end
end
