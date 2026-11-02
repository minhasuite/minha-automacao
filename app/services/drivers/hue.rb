module Drivers
  # Philips Hue (integ): Hue Bridge pela API v2 local (CLIP v2, HTTPS com
  # certificado próprio, cabeçalho `hue-application-key`). A chave sai do
  # pareamento (botão do bridge + POST /api). Cada aparelho Hue vira um
  # aparelho com os pontos dos serviços dele: luz (liga, brilho 0–100, cor
  # em xy ↔ hs), movimento e temperatura. Endereço do ponto {rtype, rid, field}.
  class Hue
    API = "/clip/v2/resource".freeze
    FIELDS = { "on" => %w[on on], "dimming" => %w[dimming brightness], "motion" => %w[motion motion], "temperature" => %w[temperature temperature] }.freeze

    def self.conn(integration)
      s = integration.settings
      { base: "https://#{s['host']}:#{(s['port'].presence || 443).to_i}", key: integration.secrets["app_key"] }
    end

    def self.get(c, path) = LanHttp.get("#{c[:base]}#{API}#{path}", headers: { "hue-application-key" => c[:key].to_s }, insecure: true).fetch("data", [])

    # Botão do bridge apertado há menos de 30 s → chave da aplicação.
    def self.pair(c)
      r = Array(LanHttp.post("#{c[:base]}/api", { devicetype: "minha_automacao#servidor", generateclientkey: true }, insecure: true)).first.to_h
      r.dig("success", "username") or raise Integrations::Error, (r.dig("error", "type") == 101 ? "Aperte o botão redondo do Hue Bridge e clique em Adicionar de novo (em até 30 s)." : "O Hue Bridge recusou o pareamento.")
    end

    def self.inventory(integration)
      c = conn(integration)
      if c[:key].blank?
        c[:key] = pair(c)
        integration.update!(credentials: integration.secrets.merge("app_key" => c[:key]).to_json)
      end
      services = %w[light motion temperature].flat_map { |t| get(c, "/#{t}").map { |r| r.merge("type" => t) } }.group_by { |r| r.dig("owner", "rid") }
      get(c, "/device").filter_map do |d|
        points = Array(services[d["id"]]).flat_map { |r| points_for(r) }
        next if points.empty?

        { "id" => "hue:#{d['id']}", "kind" => "hue", "name" => d.dig("metadata", "name") || "Hue", "manufacturer" => d.dig("product_data", "manufacturer_name") || "Signify",
          "model" => d.dig("product_data", "product_name"), "category" => "Hue", "online" => true, "poll_s" => 15, "address" => {}, "points" => points }
      end
    end

    def self.points_for(r)
      at = ->(field) { { "rtype" => r["type"], "rid" => r["id"], "field" => field } }
      case r["type"]
      when "light"
        [ { "name" => "Luz", "capability" => "onoff", "icon" => "light-bulb", "address" => at.call("on") },
          ({ "name" => "Brilho", "capability" => "dimmer", "address" => at.call("dimming") } if r["dimming"]),
          ({ "name" => "Cor", "capability" => "color", "address" => at.call("color").merge("color" => { "hs" => {} }) } if r["color"]) ].compact
      when "motion" then [ { "name" => "Movimento", "capability" => "motion", "address" => at.call("motion") } ]
      when "temperature" then [ { "name" => "Temperatura", "capability" => "measure", "unit" => "°C", "device_class" => "temperature",
                                  "state_class" => "measurement", "address" => at.call("temperature") } ]
      else []
      end
    end

    def self.value(point, r)
      f = point.address["field"]
      return (xy = r.dig("color", "xy")) && Points::Color.from_rgb(rgb_of(xy["x"], xy["y"])) if f == "color"

      v = r.dig(*FIELDS.fetch(f))
      v.is_a?(Float) && f == "dimming" ? v.round : v
    end

    def self.body(point, v)
      case point.address["field"]
      when "on" then { on: { on: v } }
      when "dimming" then { on: { on: v.to_i.positive? }, dimming: { brightness: v.to_i.clamp(0, 100) } }
      when "color" then { on: { on: true }, color: { xy: xy_of(*Points::Color.rgb(v)) } }
      end
    end

    def self.poll(device)
      c = conn(device.integration)
      device.points.reject(&:disabled).group_by { |p| p.address.values_at("rtype", "rid") }.each do |(rtype, rid), pts|
        r = get(c, "/#{rtype}/#{rid}").first or next
        pts.each { |p| (v = value(p, r)).nil? || p.report!(v) }
      end
      device.update_columns(status: "online", last_seen_at: Time.current)
    end

    def self.unavailable!(device) = Drivers.offline!(device)

    def execute(point, command, value)
      v = Points::Command.new(point, command, value).new_value
      c = self.class.conn(point.device.integration)
      LanHttp.call(:put, "#{c[:base]}#{API}/#{point.address['rtype']}/#{point.address['rid']}", body: self.class.body(point, v),
                                                                                              headers: { "hue-application-key" => c[:key].to_s }, insecure: true)
      self.class.poll(point.device)
    end

    # sRGB ↔ CIE xy (a Hue fala xy; o MA guarda hs).
    def self.xy_of(r, g, b)
      lin = [ r, g, b ].map { |x| (x = x / 255.0) > 0.04045 ? ((x + 0.055) / 1.055)**2.4 : x / 12.92 }
      x = (lin[0] * 0.4124) + (lin[1] * 0.3576) + (lin[2] * 0.1805)
      y = (lin[0] * 0.2126) + (lin[1] * 0.7152) + (lin[2] * 0.0722)
      z = (lin[0] * 0.0193) + (lin[1] * 0.1192) + (lin[2] * 0.9505)
      sum = x + y + z
      sum.zero? ? { x: 0.3227, y: 0.329 } : { x: (x / sum).round(4), y: (y / sum).round(4) }
    end

    def self.rgb_of(x, y)
      x = x.to_f
      y = [ y.to_f, 0.0001 ].max
      cx = x / y
      cz = (1 - x - y) / y
      lin = [ (cx * 3.2406) - 1.5372 - (cz * 0.4986), (-cx * 0.9689) + 1.8758 + (cz * 0.0415), (cx * 0.0557) - 0.2040 + (cz * 1.0570) ]
      top = [ lin.max, 1.0 ].max
      lin.map { |v| v = (v / top).clamp(0, 1); ((v <= 0.0031308 ? 12.92 * v : (1.055 * (v**(1 / 2.4))) - 0.055) * 255).round.clamp(0, 255) }
    end
  end
end
