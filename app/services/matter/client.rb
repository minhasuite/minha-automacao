module Matter
  # Cliente do python-matter-server (o mesmo servidor que o HA usa) por
  # WebSocket (`ws://host:5580/ws`). Ao conectar o servidor manda o
  # `server_info`; cada comando leva `message_id` e a resposta volta com o
  # mesmo id (`result` ou `error_code`/`details`). Eventos que chegam no meio
  # (`attribute_updated`, `node_updated`…) ficam em `events` para o ouvinte.
  class Client
    class Error < StandardError; end

    DEFAULT_URL = "ws://localhost:5580/ws".freeze
    TIMEOUT = 10
    COMMISSION_TIMEOUT = 120

    attr_reader :server_info, :events

    def self.open(url, ws: nil)
      client = new(url, ws: ws).connect
      yield client
    ensure
      client&.close
    end

    def initialize(url, ws: nil)
      @url = url.presence || DEFAULT_URL
      @ws = ws
      @events = []
      @seq = 0
    end

    def connect
      @ws ||= WsClient.new(@url, timeout: TIMEOUT).connect
      @server_info = @ws.read_json(TIMEOUT) or raise Error, "O servidor Matter não respondeu."
      self
    rescue WsClient::Error, JSON::ParserError => e
      raise Error, e.message
    end

    def close = @ws&.close

    # → resultado do comando; erro do servidor vira Error.
    def call(command, args = {}, timeout: TIMEOUT)
      id = (@seq += 1).to_s
      @ws.send_json({ "message_id" => id, "command" => command, "args" => args })
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        left = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        msg = (@ws.read_json(left) if left.positive?) or raise Error, "Sem resposta do servidor Matter para #{command}."
        next @events << msg if msg.key?("event")
        next unless msg["message_id"] == id
        raise Error, "#{command}: #{msg['details'] || "erro #{msg['error_code']}"}" if msg.key?("error_code")

        return msg["result"]
      end
    rescue WsClient::Error, JSON::ParserError => e
      raise Error, e.message
    end

    # Próximo evento (os guardados primeiro) ou nil depois de `timeout`.
    def next_event(timeout)
      return @events.shift if @events.any?

      msg = @ws.read_json(timeout)
      msg if msg&.key?("event")
    end

    def closed? = @events.empty? && @ws.closed?

    def start_listening = call("start_listening")
    def nodes = call("get_nodes")

    def device_command(node, endpoint, cluster, name, payload = {})
      call("device_command", { "node_id" => node, "endpoint_id" => endpoint, "cluster_id" => cluster, "command_name" => name, "payload" => payload })
    end

    def write_attribute(node, path, value) = call("write_attribute", { "node_id" => node, "attribute_path" => path, "value" => value })

    # Código de pareamento (MT:… do QR ou os 11 dígitos). `network_only`: o
    # aparelho já está na rede (Wi-Fi/Thread ou compartilhado de outro app);
    # falso = pelo Bluetooth do servidor (ondaC1), com as credenciais já mandadas.
    def commission(code, network_only: true) = call("commission_with_code", { "code" => code, "network_only" => network_only }, timeout: COMMISSION_TIMEOUT)

    # ondaC1 (C3): multi-admin, manutenção e redes para comissionar.
    def open_commissioning_window(node, timeout: 180) = call("open_commissioning_window", { "node_id" => node, "timeout" => timeout })
    def interview(node) = call("interview_node", { "node_id" => node }, timeout: COMMISSION_TIMEOUT)
    def remove_node(node) = call("remove_node", { "node_id" => node })
    def set_wifi_credentials(ssid, password) = call("set_wifi_credentials", { "ssid" => ssid, "credentials" => password })
    def set_thread_dataset(hex) = call("set_thread_dataset", { "dataset" => hex })
  end
end
