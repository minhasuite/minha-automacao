require "socket"
require "io/wait"

module Drivers
  # Yeelight (integ): lâmpada/fita pela LAN (TCP 55443, uma linha JSON por
  # pedido; ligue o "Controle pela LAN" no app Yeelight). Liga/desliga, brilho
  # (1–100) e cor RGB; leitura a cada 30 s e logo depois do comando. A
  # descoberta por multicast não entrou: informe o IP.
  class Yeelight
    PORT = 55_443
    PROPS = %w[power bright rgb name model].freeze
    TIMEOUT = 3

    class Error < Integrations::Error; end

    # → result do pedido (as notificações "props" que chegam no meio são ignoradas).
    def self.call(address, method, params)
      Socket.tcp(address["host"], (address["port"].presence || PORT).to_i, connect_timeout: TIMEOUT) do |s|
        s.write({ id: 1, method: method, params: params }.to_json + "\r\n")
        loop do
          raise Error, "A Yeelight não respondeu." unless s.wait_readable(TIMEOUT)

          line = s.gets or raise Error, "A Yeelight fechou a conexão."
          msg = JSON.parse(line)
          next unless msg["id"] == 1
          raise Error, "A Yeelight recusou #{method}: #{msg.dig('error', 'message')}" if msg["error"]

          return msg["result"]
        end
      end
    rescue SystemCallError, SocketError, IOError, JSON::ParserError => e
      raise Error, "Sem conexão com a Yeelight #{address['host']} (#{e.class.name.demodulize}). O Controle pela LAN está ligado?"
    end

    def self.read(address) = PROPS.zip(call(address, "get_prop", PROPS)).to_h

    def self.entry(integration)
      address = { "host" => integration.settings["host"], "port" => (integration.settings["port"].presence || PORT).to_i }
      r = read(address)
      { "id" => "yeelight:#{address['host']}", "kind" => "yeelight", "name" => r["name"].presence || "Yeelight #{address['host']}", "manufacturer" => "Yeelight",
        "model" => r["model"].presence, "category" => "Luz", "online" => true, "poll_s" => 30, "address" => address,
        "points" => [ { "name" => "Luz", "capability" => "onoff", "icon" => "light-bulb", "address" => { "prop" => "power" } },
                      { "name" => "Brilho", "capability" => "dimmer", "min" => 1, "max" => 100, "address" => { "prop" => "bright" } },
                      ({ "name" => "Cor", "capability" => "color", "address" => { "prop" => "rgb", "color" => { "hs" => {} } } } if r["rgb"].to_s.match?(/\A\d+\z/)) ].compact }
    end

    def self.value(point, r)
      raw = r[point.address["prop"]].to_s
      return if raw.empty?

      case point.address["prop"]
      when "power" then raw == "on"
      when "bright" then raw.to_i
      when "rgb" then (i = raw.to_i) && Points::Color.from_rgb([ (i >> 16) & 255, (i >> 8) & 255, i & 255 ])
      end
    end

    def self.request(point, v)
      case point.address["prop"]
      when "power" then [ "set_power", [ v ? "on" : "off", "smooth", 300 ] ]
      when "bright" then [ "set_bright", [ v.to_i.clamp(1, 100), "smooth", 300 ] ]
      when "rgb" then [ "set_rgb", [ Points::Color.rgb(v).then { |r, g, b| (r << 16) | (g << 8) | b }, "smooth", 300 ] ]
      end
    end

    def self.poll(device)
      r = read(device.address)
      device.update_columns(status: "online", last_seen_at: Time.current)
      device.points.reject(&:disabled).each { |p| (v = value(p, r)).nil? || p.report!(v) }
    end

    def self.unavailable!(device) = Drivers.offline!(device)

    def execute(point, command, value)
      v = Points::Command.new(point, command, value).new_value
      self.class.call(point.device.address, *self.class.request(point, v))
      self.class.poll(point.device)
    end
  end
end
