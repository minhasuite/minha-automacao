module Drivers
  # WLED (integ): fita/painel de LED pela JSON API do aparelho (`/json`,
  # `/json/state`). Liga/desliga, brilho (0–255), cor do segmento principal e
  # efeito. Achado por mDNS `_wled._tcp`; leitura a cada 30 s e logo depois
  # de cada comando. Endereço do aparelho {host, port}; ponto {field}.
  class Wled
    def self.base(address) = "http://#{address['host']}:#{address['port'].presence || 80}"

    def self.entry(integration)
      address = { "host" => integration.settings["host"], "port" => (integration.settings["port"].presence || 80).to_i }
      j = LanHttp.get("#{base(address)}/json")
      info = j["info"].to_h
      { "id" => "wled:#{info['mac'].presence || address['host']}", "kind" => "wled", "name" => info["name"].presence || "WLED", "manufacturer" => "WLED",
        "model" => info["arch"], "category" => "WLED #{info['ver']}".strip, "online" => true, "poll_s" => 30, "address" => address,
        "points" => [ { "name" => "Luz", "capability" => "onoff", "icon" => "light-bulb", "address" => { "field" => "on" } },
                      { "name" => "Brilho", "capability" => "dimmer", "min" => 0, "max" => 255, "address" => { "field" => "bri" } },
                      { "name" => "Cor", "capability" => "color", "address" => { "field" => "col" } },
                      ({ "name" => "Efeito", "capability" => "enum", "options" => j["effects"], "address" => { "field" => "fx" } } if Array(j["effects"]).any?) ].compact }
    end

    def self.value(point, state)
      seg = Array(state["seg"]).first.to_h
      case point.address["field"]
      when "on" then state["on"] == true
      when "bri" then state["bri"]
      when "col" then (rgb = Array(seg["col"]).first) && Points::Color.from_rgb(rgb.first(3))
      when "fx" then Array(point.options)[seg["fx"].to_i]
      end
    end

    def self.body(point, v)
      case point.address["field"]
      when "on" then { on: v }
      when "bri" then { on: v.to_i.positive?, bri: v.to_i }
      when "col" then { on: true, seg: [ { col: [ Points::Color.rgb(v) ] } ] }
      when "fx" then { seg: [ { fx: Array(point.options).index(v) } ] }
      end
    end

    def self.poll(device)
      state = LanHttp.get("#{base(device.address)}/json/state")
      device.update_columns(status: "online", last_seen_at: Time.current)
      device.points.reject(&:disabled).each { |p| (v = value(p, state)).nil? || p.report!(v) }
    end

    def self.unavailable!(device) = Drivers.offline!(device)

    def execute(point, command, value)
      v = Points::Command.new(point, command, value).new_value
      LanHttp.post("#{self.class.base(point.device.address)}/json/state", self.class.body(point, v))
      self.class.poll(point.device)
    end
  end
end
