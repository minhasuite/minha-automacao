require "socket"

module Drivers
  # Govee (integ2): lâmpadas e fitas pela API LAN da Govee (UDP, JSON; ligar
  # "Controle LAN" no app). Descoberta: "scan" no multicast 239.255.255.250:4001,
  # respostas na 4002. Comando e "devStatus" vão para o aparelho na 4003; o
  # estado volta na 4002. Endereço {host, port}.
  class Govee
    MULTICAST = "239.255.255.250".freeze
    SCAN_PORT = 4001
    LISTEN_PORT = 4002
    PORT = 4003
    WAIT = 2

    # Socket que escuta a 4002 (onde a Govee responde) e manda pelo mesmo.
    def self.socket
      sock = UDPSocket.new
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
      sock.bind("0.0.0.0", LISTEN_PORT)
      yield sock
    ensure
      sock&.close
    end

    def self.send_msg(sock, host, port, cmd, data = {}) = sock.send({ msg: { cmd: cmd, data: data } }.to_json, 0, host, port)

    # Próxima mensagem [cmd, data, ip] ou nil.
    def self.receive(sock, timeout)
      return unless sock.wait_readable(timeout)

      text, from = sock.recvfrom(4096)
      msg = JSON.parse(text)["msg"].to_h
      [ msg["cmd"], msg["data"].to_h, from[3] ]
    rescue JSON::ParserError
      [ nil, {}, nil ]
    end

    # Achados na rede → [{"name", "host", "port", "txt"}].
    def self.discover(wait: WAIT)
      socket do |sock|
        send_msg(sock, MULTICAST, SCAN_PORT, "scan", { account_topic: "reserve" })
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
        found = {}
        while (left = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)).positive?
          cmd, data, = receive(sock, left)
          next unless cmd == "scan" && data["ip"].present?

          found[data["ip"]] = { "name" => "Govee #{data['sku']}".strip, "host" => data["ip"], "port" => PORT, "txt" => data.slice("device", "sku") }
        end
        found.values
      end
    rescue SystemCallError, IOError
      []
    end

    def self.status(host, port = PORT)
      socket do |sock|
        send_msg(sock, host, port, "devStatus")
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WAIT
        while (left = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)).positive?
          cmd, data, from = receive(sock, left)
          return data if cmd == "devStatus" && from == host
        end
        raise Integrations::Error, "A Govee em #{host} não respondeu (Controle LAN ligado no app?)."
      end
    rescue SystemCallError, IOError => e
      raise Integrations::Error, "Sem conexão com #{host} (#{e.class.name.demodulize})."
    end

    def self.entry(integration)
      host = integration.settings["host"]
      port = (integration.settings["port"].presence || PORT).to_i
      status(host, port)
      { "id" => host, "match" => "host", "kind" => "govee", "name" => integration.name, "manufacturer" => "Govee", "category" => "Govee", "online" => true,
        "poll_s" => 30, "address" => { "host" => host, "port" => port },
        "points" => [ { "name" => "Luz", "capability" => "onoff", "icon" => "light-bulb", "address" => { "field" => "onOff" } },
                      { "name" => "Brilho", "capability" => "dimmer", "min" => 1, "max" => 100, "address" => { "field" => "brightness" } },
                      { "name" => "Cor", "capability" => "color", "address" => { "field" => "color" } } ] }
    end

    def self.value(point, s)
      case point.address["field"]
      when "onOff" then s["onOff"].to_i == 1
      when "brightness" then s["brightness"]&.to_i
      when "color" then (c = s["color"]).is_a?(Hash) ? Points::Color.from_rgb(c.values_at("r", "g", "b").map(&:to_i)) : nil
      end
    end

    def self.poll(device)
      s = status(device.address["host"], (device.address["port"].presence || PORT).to_i)
      device.update_columns(status: "online", last_seen_at: Time.current)
      device.points.reject(&:disabled).each { |p| (v = value(p, s)).nil? || p.report!(v) }
    end

    def self.unavailable!(device) = Drivers.offline!(device)

    # Campo do ponto + valor → [comando, dados] da API LAN.
    def self.message(field, v)
      case field
      when "onOff" then [ "turn", { value: v ? 1 : 0 } ]
      when "brightness" then [ "brightness", { value: v.to_i.clamp(1, 100) } ]
      when "color"
        r, g, b = Points::Color.rgb(v)
        [ "colorwc", { color: { r: r, g: g, b: b }, colorTemInKelvin: 0 } ]
      end
    end

    def execute(point, command, value)
      v = Points::Command.new(point, command, value).new_value
      cmd, data = self.class.message(point.address["field"], v)
      a = point.device.address
      UDPSocket.open { |s| self.class.send_msg(s, a["host"], (a["port"].presence || PORT).to_i, cmd, data) }
      sleep 0.3 # a Govee aplica antes de responder o estado
      self.class.poll(point.device)
    end
  end
end
