# Z-Wave JS (integ2): cliente do zwave-js-server (o mesmo do add-on Z-Wave JS
# do HA e do Z-Wave JS UI) por WebSocket (`ws://host:3000`). Ao conectar o
# servidor manda a versão; o cliente fixa o esquema da API e pede o estado
# (`start_listening` → controlador e nós com os valores). Cada comando leva
# `messageId` e a resposta volta com o mesmo id (`success`, `result`); os
# eventos que chegam no meio ficam em `events` (ondaC1: ouvinte em tempo
# real, ZwaveJs::Listener). Valores → pontos pelo `config/device_maps/zwave.yml`.
#
# ondaC1 (C1): inclusão segura (S2 com PIN do DSK, S0, sem segurança e
# SmartStart pelo QR), exclusão, remover nó com falha, refazer rotas, vizinhos
# (mapa da rede), reentrevista e firmware pela nuvem do Z-Wave JS.
module ZwaveJs
  class Error < StandardError; end

  SCHEMA = 35
  TIMEOUT = 10
  MAP = YAML.load_file(Rails.root.join("config/device_maps/zwave.yml")).freeze
  # InclusionStrategy do zwave-js: padrão (S2 se o aparelho tiver, senão S0), sem segurança, só S2.
  STRATEGIES = { "default" => 0, "insecure" => 2, "s2" => 4 }.freeze
  # SecurityClass do zwave-js (o que a pessoa concede na inclusão S2).
  SECURITY_CLASSES = { 0 => "s2_unauthenticated", 1 => "s2_authenticated", 2 => "s2_access_control", 7 => "s0_legacy" }.freeze
  STATUS = { 0 => "unknown", 1 => "asleep", 2 => "awake", 3 => "dead", 4 => "alive" }.freeze

  class Client
    attr_reader :version, :events

    def self.open(url, ws: nil)
      c = new(url, ws: ws).connect
      yield c
    ensure
      c&.close
    end

    def initialize(url, ws: nil)
      @url = url
      @ws = ws
      @seq = 0
      @events = []
    end

    def connect
      @ws ||= WsClient.new(@url, timeout: TIMEOUT).connect
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
        next @events << msg if msg["type"] == "event"
        next unless msg["type"] == "result" && msg["messageId"] == id
        raise Error, "#{command}: #{msg['message'] || msg['errorCode']}" unless msg["success"]

        return msg["result"]
      end
    rescue WsClient::Error, JSON::ParserError => e
      raise Error, e.message
    end

    # Próximo evento (os guardados primeiro) ou nil depois de `timeout`.
    def next_event(timeout)
      return @events.shift if @events.any?

      msg = @ws.read_json(timeout)
      msg if msg.is_a?(Hash) && msg["type"] == "event"
    rescue WsClient::Error, JSON::ParserError => e
      raise Error, e.message
    end

    def closed? = @events.empty? && @ws.closed?

    def state = call("start_listening")["state"].to_h

    def set_value(node, value_id, value) = call("node.set_value", "nodeId" => node, "valueId" => value_id, "value" => value)

    # Rede (ondaC1).
    def begin_inclusion(strategy) = call("controller.begin_inclusion", "options" => { "strategy" => strategy })
    def stop_inclusion = call("controller.stop_inclusion")
    def begin_exclusion = call("controller.begin_exclusion")
    def stop_exclusion = call("controller.stop_exclusion")
    def grant(classes) = call("controller.grant_security_classes", "inclusionGrant" => { "securityClasses" => classes, "clientSideAuth" => false })
    def validate_dsk(pin) = call("controller.validate_dsk_and_enter_pin", "pin" => pin)
    def provision(qr) = call("controller.provision_smart_start_node", "entry" => qr)
    def provisioning_entries = Array(call("controller.get_provisioning_entries")["entries"])
    def unprovision(dsk) = call("controller.unprovision_smart_start_node", "dskOrNodeId" => dsk)
    def neighbors(node) = Array(call("controller.get_node_neighbors", "nodeId" => node)["neighbors"])
    def rebuild_routes = call("controller.begin_rebuilding_routes")
    def remove_failed(node) = call("controller.remove_failed_node", "nodeId" => node)
    def reinterview(node) = call("node.refresh_info", "nodeId" => node)
    def firmware_updates(node) = Array(call("controller.get_available_firmware_updates", "nodeId" => node, "includePrereleases" => false)["updates"])
    def firmware_update!(node, update) = call("controller.firmware_update_ota", "nodeId" => node, "updateInfo" => update)
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
      if rule["notification"]
        rule = MAP.dig("notifications", "#{v['property']}/#{v['propertyKey']}") or next
        rule = rule.merge("notification" => true)
      end
      meta = v["metadata"].to_h
      next if meta["readable"] == false || (rule["read"] && v["property"] != rule["read"])

      unit = rule["unit"] || meta["unit"]
      cap = rule["capability"]
      cap = "motion" if cap == "contact" && rule["motion"] && v["property"].to_s.match?(/#{rule['motion']}/i)
      name = rule["name"] || meta["label"].presence || v["propertyName"] || v["property"].to_s
      name = "#{name} #{v['endpoint']}" if v["endpoint"].to_i.positive?
      { "name" => name, "capability" => cap, "unit" => unit, "device_class" => rule["device_class"] || MAP.dig("units", unit),
        "state_class" => rule["state_class"] || (unit == "kWh" ? "total_increasing" : ("measurement" if cap == "measure")),
        "min" => rule["min"] || meta["min"], "max" => rule["max"] || meta["max"], "step" => rule["step"], "history" => rule["history"],
        "writable" => (false if rule["notification"] || cap == "event"),
        "address" => { "node" => node["nodeId"], "cc" => v["commandClass"], "endpoint" => v["endpoint"].to_i, "property" => v["property"],
                       "property_key" => v["propertyKey"], "write" => rule["write"], "on" => rule["on"] }.compact }.compact
    end
  end

  def same?(address, v)
    address["cc"] == v["commandClass"] && address["endpoint"].to_i == v["endpoint"].to_i &&
      address["property"].to_s == v["property"].to_s && address["property_key"].to_s == v["propertyKey"].to_s
  end

  # Bruto → valor do ponto (notificação: o estado está na lista `on` = ativo).
  def value(point, raw)
    return if raw.nil?
    return Array(point.address["on"]).include?(raw.to_i) if point.address["on"]

    point.from_raw(raw)
  end

  def apply(device, node)
    device.update_columns(status: node["status"] == 3 ? "offline" : "online", last_seen_at: Time.current)
    device.points.reject(&:disabled).each do |p|
      v = Array(node["values"]).find { |x| same?(p.address, x) }
      p.report!(value(p, v["value"])) if v && !v["value"].nil?
    end
  end

  def value_id(address)
    { "commandClass" => address["cc"], "endpoint" => address["endpoint"].to_i, "property" => address["write"] || address["property"],
      "propertyKey" => address["property_key"] }.compact
  end

  # Mapa da rede: controlador no centro, nós num círculo, arestas pelos vizinhos.
  # → {nodes: [{id, name, status, x, y, controller}], edges: [[a, b]]} (coordenadas 0–100).
  def network_map(nodes, neighbors)
    ctrl, others = nodes.partition { |n| n["isControllerNode"] }
    placed = ctrl.map { |n| [ n, 50.0, 50.0 ] } + others.each_with_index.map do |n, i|
      a = (2 * Math::PI * i / [ others.size, 1 ].max) - (Math::PI / 2)
      [ n, (50 + (40 * Math.cos(a))).round(1), (50 + (40 * Math.sin(a))).round(1) ]
    end
    ids = nodes.to_set { |n| n["nodeId"] }
    edges = neighbors.flat_map { |id, list| Array(list).select { |o| ids.include?(o) }.map { |o| [ id, o ].sort } }.uniq
    { nodes: placed.map { |n, x, y| { id: n["nodeId"], name: n["name"].presence || n.dig("deviceConfig", "label") || "Nó #{n['nodeId']}", status: STATUS.fetch(n["status"], "unknown"),
                                      x: x, y: y, controller: n["isControllerNode"] == true, secure: n["isSecure"] == true } },
      edges: edges }
  end

  # Estado da inclusão/exclusão entre a tela (web) e o ouvinte (worker), no cache
  # compartilhado (Solid Cache). A tela pede (`requested`, `granted`, `pin`,
  # `stop`); o ouvinte executa e anota o que o servidor responde (`running`,
  # `grant`, `dsk`, `added`, `done`, `removed`, `stopped`, `failed`).
  module Inclusion
    TTL = 10.minutes
    ACTIVE = %w[requested running grant granted dsk pin added stop].freeze

    module_function

    def key(id) = "zwave_js:inclusion:#{id}"
    def get(id) = Rails.cache.read(key(id)) || {}
    def set(id, h) = Rails.cache.write(key(id), h.stringify_keys.merge("at" => Time.current.iso8601), expires_in: TTL)
    def update(id, **h) = set(id, get(id).merge(h.stringify_keys))
    def active?(id) = ACTIVE.include?(get(id)["state"])
    def clear(id) = Rails.cache.delete(key(id))
  end
end
