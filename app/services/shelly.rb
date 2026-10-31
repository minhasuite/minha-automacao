require "net/http"

# Shelly pela rede de casa (Pacote 1). Gen1: HTTP (`/shelly`, `/status`,
# `/settings`, `/relay|light|roller/N?...`, Basic opcional). Gen2+: RPC JSON
# em `POST /rpc` (Digest SHA-256 opcional, usuário `admin`). A geração vem
# do `/shelly` (sem `gen` = 1). Pontos pelo mapa `config/device_maps/shelly.yml`:
# endereço {path (no estado), cmd, id, map?}. Só leitura periódica; o tempo
# real (CoAP no Gen1, WebSocket no Gen2) não entrou.
module Shelly
  class Error < Integrations::Error; end

  MAP = YAML.load_file(Rails.root.join("config/device_maps/shelly.yml")).freeze
  USER = "admin".freeze # ponytail: usuário fixo (Gen2 só aceita admin; Gen1 padrão); campo próprio se alguém trocar no Gen1
  ATTRS = %w[name capability unit device_class state_class min max step options].freeze

  # cmd do ponto → pedido: Gen1 [caminho com query], Gen2 [método, params].
  # O valor já vem validado pelo Points::Command (bool, número ou opção).
  COMMANDS = {
    "relay" => ->(_p, id, v) { "/relay/#{id}?turn=#{v ? 'on' : 'off'}" },
    "light" => ->(p, id, v) { p.capability == "dimmer" ? "/light/#{id}?turn=on&brightness=#{v.to_i}" : "/light/#{id}?turn=#{v ? 'on' : 'off'}" },
    "roller" => ->(p, id, v) { p.capability == "setpoint" ? "/roller/#{id}?go=to_pos&roller_pos=#{v.to_i}" : "/roller/#{id}?go=#{v}" },
    "switch" => ->(_p, id, v) { [ "Switch.Set", { id: id, on: v } ] },
    "light_rpc" => ->(p, id, v) { p.capability == "dimmer" ? [ "Light.Set", { id: id, on: true, brightness: v.to_i } ] : [ "Light.Set", { id: id, on: v } ] },
    "cover" => ->(p, id, v) { p.capability == "setpoint" ? [ "Cover.GoToPosition", { id: id, pos: v.to_i } ] : [ "Cover.#{v.to_s.capitalize}", { id: id } ] }
  }.freeze

  module_function

  # Integração (LanPlugin) → uma entrada de inventário.
  def inventory_entry(integration)
    conn = { "host" => integration.settings["host"], "port" => integration.settings["port"].presence || 80, "password" => integration.secrets["password"] }
    info = get(conn, "/shelly")
    gen = info["gen"].to_i.positive? ? info["gen"].to_i : 1
    conn["gen"] = gen
    if gen == 1
      settings = get(conn, "/settings")
      status = get(conn, "/status")
      name = settings["name"].presence || settings.dig("device", "hostname")
      model = info["type"]
      skip = settings["mode"] == "roller" ? %w[relays] : []
    else
      dev = rpc(conn, "Shelly.GetDeviceInfo")
      status = rpc(conn, "Shelly.GetStatus")
      name = dev["name"].presence || dev["id"]
      model = dev["model"] || info["model"]
      skip = []
    end
    { "id" => info["mac"].to_s.downcase, "kind" => "shelly", "name" => name.presence || "Shelly #{conn['host']}", "manufacturer" => "Shelly",
      "model" => model, "category" => "Shelly Gen#{gen}", "online" => true, "poll_s" => 30,
      "address" => { "host" => conn["host"], "port" => conn["port"].to_i, "gen" => gen }, "points" => points(gen, status, skip) }
  end

  # Estado → atributos de ponto pelo mapa (índice no nome quando há mais de um).
  def points(gen, status, skip = [])
    comps = gen == 1 ? gen1_components(status, skip) : gen2_components(status)
    counts = comps.map(&:first).tally
    comps.flat_map do |type, id, key, item|
      Array(MAP.dig(gen == 1 ? "gen1" : "gen2", type)).filter_map do |f|
        next if item.dig(*f["field"].split(".")).nil?

        attrs = { "capability" => "measure" }.merge(f.slice(*ATTRS))
        attrs["name"] = "#{attrs['name']} #{id + 1}" if counts[type] > 1
        attrs["scale"] = f["scale"] if f["scale"]
        attrs.merge("address" => { "path" => [ *key, *f["field"].split(".") ], "cmd" => f["cmd"], "id" => id, "map" => f["map"] }.compact)
      end
    end
  end

  # [tipo, índice, caminho até o item, item]
  def gen1_components(status, skip)
    MAP["gen1"].keys.reject { |k| skip.include?(k) }.flat_map do |type|
      Array(status[type]).each_with_index.map { |item, i| [ type, i, [ type, i ], item ] }
    end
  end

  def gen2_components(status)
    status.filter_map do |key, item|
      type, id = key.split(":")
      [ type, id.to_i, [ key ], item ] if id && MAP["gen2"].key?(type) && item.is_a?(Hash)
    end
  end

  # Estado atual → valores dos pontos do aparelho.
  def status(conn) = conn["gen"].to_i >= 2 ? rpc(conn, "Shelly.GetStatus") : get(conn, "/status")

  def value_for(point, status)
    raw = status.dig(*point.address["path"])
    return if raw.nil?

    raw = point.address["map"].fetch(raw.to_s, raw) if point.address["map"]
    point.from_raw(raw)
  end

  def command(conn, point, value)
    req = COMMANDS.fetch(point.address["cmd"]).call(point, point.address["id"].to_i, value)
    req.is_a?(Array) ? rpc(conn, *req) : get(conn, req)
  end

  def get(conn, path) = request(conn, Net::HTTP::Get, path)

  def rpc(conn, method, params = {})
    res = request(conn, Net::HTTP::Post, "/rpc", { id: 1, method: method, params: params })
    raise Error, "O Shelly recusou #{method}: #{res.dig('error', 'message')}" if res["error"]

    res["result"] || {}
  end

  # JSON de ida e volta; Gen1 com Basic, Gen2 com Digest no 401.
  def request(conn, verb, path, body = nil)
    uri = URI("http://#{conn['host']}:#{conn['port'].presence || 80}#{path}")
    build = lambda do
      req = verb.new(uri)
      req.body = body.to_json if body
      req["Content-Type"] = "application/json" if body
      req.basic_auth(USER, conn["password"]) if conn["password"].present? && conn["gen"].to_i == 1
      req
    end
    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) do |http|
      res = http.request(build.call)
      if res.code == "401" && conn["password"].present? && res["www-authenticate"].to_s.start_with?("Digest")
        req = build.call
        req["Authorization"] = Isapi.digest(res["www-authenticate"], USER, conn["password"], uri.request_uri, method: req.method)
        res = http.request(req)
      end
      raise Integrations.auth(Error.new("Senha do Shelly não confere.")) if res.code == "401"
      raise Error, "O Shelly respondeu #{res.code}." unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)
    end
  rescue SystemCallError, SocketError, Timeout::Error, IOError, JSON::ParserError => e
    raise Error, "Sem conexão com #{conn['host']} (#{e.class.name.demodulize})."
  end
end
