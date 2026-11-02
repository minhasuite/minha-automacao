# Z-Wave JS (integ2): cliente do zwave-js-server (o mesmo do add-on Z-Wave JS
# do HA e do Z-Wave JS UI) por WebSocket (`ws://host:3000`). Ao conectar o
# servidor manda a versão; o cliente fixa o esquema da API e pede o estado
# (`start_listening` → controlador e nós com os valores). Cada comando leva
# `messageId` e a resposta volta com o mesmo id (`success`, `result`).
# Valores → pontos pelo `config/device_maps/zwave.yml`.
module ZwaveJs
  class Error < StandardError; end

  SCHEMA = 35
  TIMEOUT = 10
  MAP = YAML.load_file(Rails.root.join("config/device_maps/zwave.yml")).freeze

  class Client
    attr_reader :version

    def self.open(url)
      c = new(url).connect
      yield c
    ensure
      c&.close
    end

    def initialize(url)
      @url = url
      @seq = 0
    end

    def connect
      @ws = WsClient.new(@url, timeout: TIMEOUT).connect
      @version = @ws.read_json(TIMEOUT) or raise Error, "O servidor Z-Wave JS não respondeu."
      call("set_api_schema", "schemaVersion" => [ @version["maxSchemaVersion"].to_i, SCHEMA ].min.clamp(1, SCHEMA))
      self
    rescue WsClient::Error, JSON::ParserError => e
      raise Error, e.message
    end

    def close = @ws&.close

    def call(command, args = {})
      id = (@seq += 1).to_s
      @ws.send_json(args.merge("messageId" => id, "command" => command))
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
      loop do
        left = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        msg = (@ws.read_json(left) if left.positive?) or raise Error, "Sem resposta do Z-Wave JS para #{command}."
        next unless msg["type"] == "result" && msg["messageId"] == id
        raise Error, "#{command}: #{msg['message'] || msg['errorCode']}" unless msg["success"]

        return msg["result"]
      end
    rescue WsClient::Error, JSON::ParserError => e
      raise Error, e.message
    end

    def state = call("start_listening")["state"].to_h

    def set_value(node, value_id, value) = call("node.set_value", "nodeId" => node, "valueId" => value_id, "value" => value)
  end

  module_function

  def entry(home, node)
    cfg = node["deviceConfig"].to_h
    { "id" => "zwave:#{home}:#{node['nodeId']}", "kind" => "zwave_js", "name" => node["name"].presence || cfg["description"].presence || "Nó #{node['nodeId']}",
      "manufacturer" => cfg["manufacturer"], "model" => cfg["label"], "category" => "Z-Wave", "room" => node["location"].presence,
      "online" => node["status"] != 3, "poll_s" => 300, "address" => { "node" => node["nodeId"] }, "points" => points(node) }
  end

  # Valores do nó → atributos de ponto (só os que o mapa conhece e que dá para ler).
  def points(node)
    Array(node["values"]).filter_map do |v|
      rule = MAP.dig("command_classes", v["commandClass"]) or next
      meta = v["metadata"].to_h
      next if meta["readable"] == false || (rule["read"] && v["property"] != rule["read"])

      unit = rule["unit"] || meta["unit"]
      cap = rule["capability"]
      cap = "motion" if cap == "contact" && v["property"].to_s.match?(/#{rule['motion']}/i)
      name = rule["name"] || meta["label"].presence || v["propertyName"] || v["property"].to_s
      name = "#{name} #{v['endpoint']}" if v["endpoint"].to_i.positive?
      { "name" => name, "capability" => cap, "unit" => unit, "device_class" => rule["device_class"] || MAP.dig("units", unit),
        "state_class" => rule["state_class"] || (unit == "kWh" ? "total_increasing" : ("measurement" if cap == "measure")),
        "min" => rule["min"] || meta["min"], "max" => rule["max"] || meta["max"], "step" => rule["step"],
        "address" => { "node" => node["nodeId"], "cc" => v["commandClass"], "endpoint" => v["endpoint"].to_i, "property" => v["property"],
                       "property_key" => v["propertyKey"], "write" => rule["write"] }.compact }.compact
    end
  end

  def same?(address, v)
    address["cc"] == v["commandClass"] && address["endpoint"].to_i == v["endpoint"].to_i &&
      address["property"].to_s == v["property"].to_s && address["property_key"].to_s == v["propertyKey"].to_s
  end

  def apply(device, node)
    device.update_columns(status: node["status"] == 3 ? "offline" : "online", last_seen_at: Time.current)
    device.points.reject(&:disabled).each do |p|
      v = Array(node["values"]).find { |x| same?(p.address, x) }
      p.report!(p.from_raw(v["value"])) if v && !v["value"].nil?
    end
  end

  def value_id(address)
    { "commandClass" => address["cc"], "endpoint" => address["endpoint"].to_i, "property" => address["write"] || address["property"],
      "propertyKey" => address["property_key"] }.compact
  end
end
