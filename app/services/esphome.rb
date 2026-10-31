# ESPHome pela API nativa (Pacote 1): `Esphome::Client` (TCP 6053, com ou
# sem criptografia Noise), entidades → pontos pelo mapa
# `config/device_maps/esphome.yml` e o valor de cada mensagem de estado.
# Endereço do ponto: {key (da entidade), kind, field?, position?, decimals?}.
module Esphome
  class Error < StandardError; end

  module_function

  def map = @map ||= YAML.load_file(Rails.root.join("config/device_maps/esphome.yml"))

  # Uma conexão de leitura: info, entidades e o estado atual.
  def read(host:, port:, key: nil, password: nil)
    Client.open(host: host, port: port, key: key, password: password) do |c|
      info = c.device_info
      entities = c.list_entities
      c.subscribe_states
      [ info, entities, c.states(3, entities.filter_map { |e| e[:key] unless e[:kind] == "button" }) ]
    end
  end

  # Entidades → atributos de ponto (formato da adoção em `Integrations`).
  def points(entities) = entities.flat_map { |e| point_attrs(e) }

  def point_attrs(e)
    base = { "name" => e[:name].presence || e[:object_id], "address" => { "key" => e[:key], "kind" => e[:kind] } }
    case e[:kind]
    when "binary_sensor"
      cap = map.dig("binary_sensor", "classes", e[:device_class]) || map.dig("binary_sensor", "default")
      [ base.merge("capability" => cap, "device_class" => e[:device_class]) ]
    when "light" then light(e, base)
    when "cover"
      [ base.merge("capability" => "setpoint", "unit" => "%", "min" => 0, "max" => 100, "step" => 1, "device_class" => e[:device_class],
                   "risk" => map.dig("cover", "risk", e[:device_class]) || "normal",
                   "address" => base["address"].merge("position" => e[:supports_position] == true)) ]
    else
      spec = map.dig("kinds", e[:kind]) or return []
      [ base.merge(spec).merge(extras(e)).compact ]
    end
  end

  def light(e, base)
    on = base.merge("capability" => "onoff", "address" => base["address"].merge("field" => "state"))
    dim = e[:legacy_brightness] || Array(e[:color_modes]).any? { |m| (m & map["brightness_bit"]).positive? }
    return [ on ] unless dim

    [ on, base.merge("name" => "#{base['name']} brilho", "capability" => "dimmer", "min" => 0, "max" => 100,
                     "address" => base["address"].merge("field" => "brightness")) ]
  end

  def extras(e)
    { "unit" => e[:unit], "device_class" => e[:device_class], "state_class" => map.dig("state_class", e[:state_class]),
      "min" => e[:min], "max" => e[:max], "step" => e[:step]&.then { |s| s.positive? ? s : nil },
      "address" => { "key" => e[:key], "kind" => e[:kind], "decimals" => e[:decimals] }.compact }
  end

  # Estado (tipo, campos) → valor do ponto; nil = sem valor (missing_state, NaN).
  def value(point, kind, f)
    a = point.address
    case kind
    when "binary_sensor", "switch" then f[3]&.first == 1 ? nil : f[2]&.first == 1
    when "light" then a["field"] == "brightness" ? (Proto.float(f[3]&.first).to_f * 100).round : f[2]&.first == 1
    when "cover" then (Proto.float(f[3]&.first).to_f * 100).round
    when "text_sensor" then f[3]&.first == 1 ? nil : Proto.string(f[2]&.first).to_s
    when "sensor", "number"
      v = Proto.float(f[2]&.first)
      return if v.nil? || v.nan? || f[3]&.first == 1

      a["decimals"] ? v.round(a["decimals"].to_i) : v
    end
  end

  # Estados lidos ({chave → [tipo, campos]}) → pontos do aparelho.
  def report(device, states)
    device.update_columns(status: "online", last_seen_at: Time.current)
    device.points.each do |p|
      kind, f = states[p.address["key"].to_i]
      next unless kind
      v = value(p, kind, f)
      p.report!(v) unless v.nil? || (p.value == v && p.quality == "good")
    end
  end

  def client_for(device)
    s = device.integration&.secrets || {}
    Client.new(host: device.address["host"], port: device.address["port"], key: s["encryption_key"], password: s["password"])
  end
end
