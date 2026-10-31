module Mqtt
  # Descoberta do Tasmota (Pacote 1) pelo broker do servidor: as mensagens
  # retidas `tasmota/discovery/<MAC>/config` (tópicos, relés, luz) e
  # `/sensors` (leitura de exemplo do tele/SENSOR) viram aparelho `mqtt`
  # (external_id = MAC) e pontos que o Drivers::Mqtt já entende: relé no
  # `stat/<t>/RESULT` (POWER ou POWERn, ON/OFF) com comando em
  # `cmnd/<t>/POWERn`, brilho em Dimmer e sensores no `tele/<t>/SENSOR`.
  # Nomes e unidades em config/device_maps/tasmota.yml. Idempotente pelo
  # caminho do ponto. O local é o mesmo do zigbee2mqtt (Z2m.site).
  module Tasmota
    PREFIX = "tasmota/discovery/".freeze
    MAP = YAML.load_file(Rails.root.join("config/device_maps/tasmota.yml")).freeze
    @pending = {} # sensores que chegaram antes da configuração (os dois são retidos)

    module_function

    def topics = Z2m.site ? [ "#{PREFIX}#" ] : []
    def handles?(topic) = topic.start_with?(PREFIX)

    def handle(topic, payload)
      site = Z2m.site or return
      mac, kind = topic.delete_prefix(PREFIX).split("/")
      data = JSON.parse(payload)
      return unless data.is_a?(Hash) && mac.present?

      count = { devices: 0, points: 0 }
      ActsAsTenant.with_tenant(site.tenant) { kind == "config" ? config!(site, mac, data, count) : (sensors!(site, mac, data, count) if kind == "sensors") }
      count
    rescue JSON::ParserError
      nil # retido vazio = aparelho saiu da descoberta
    end

    def config!(site, mac, c, count)
      t = ->(i) { c["ft"].to_s.gsub("%prefix%", Array(c["tp"])[i].to_s).gsub("%topic%", c["t"].to_s).gsub("%hostname%", c["hn"].to_s).gsub("%id%", mac) }
      device = site.devices.find_or_initialize_by(driver: "mqtt", external_id: mac)
      count[:devices] += 1 if device.new_record?
      device.update!(name: c["dn"].presence || c["hn"].presence || "Tasmota #{mac}", manufacturer: "Tasmota", model: c["md"],
                     address: device.address.merge("cmnd" => t.call(0), "stat" => t.call(1), "tele" => t.call(2)))
      outputs = Array(c["rl"]).each_with_index.select { |type, _| MAP["relay_types"].key?(type.to_i) }
      outputs.each do |_, i|
        key = outputs.one? ? "POWER" : "POWER#{i + 1}"
        name = Array(c["fn"])[i].presence || "Liga/desliga#{" #{i + 1}" unless outputs.one?}"
        point!(device, key, count, name: name, capability: "onoff", address: command(device, key).merge("payload_on" => "ON", "payload_off" => "OFF"))
      end
      point!(device, "Dimmer", count, name: "Brilho", capability: "dimmer", address: command(device, "Dimmer")) if c["lt_st"].to_i.positive?
      (pending = @pending.delete(mac)) && sensors!(site, mac, pending, count)
    end

    def command(device, key)
      { "topic" => "#{device.address['stat']}RESULT", "json_path" => key, "command_topic" => "#{device.address['cmnd']}#{key}", "command_json_path" => "" }
    end

    def sensors!(site, mac, data, count)
      device = site.devices.find_by(driver: "mqtt", external_id: mac)
      return @pending[mac] = data unless device&.address&.key?("tele")

      leaves(data["sn"].to_h).each do |path|
        leaf = path.last
        info = MAP["sensors"][leaf] || { "name" => leaf.underscore.humanize }
        group = path.first if path.size > 1 && path.first != "ENERGY"
        point!(device, path.join("."), count, **info.symbolize_keys, name: [ info["name"], group ].compact.join(" "), capability: "measure",
                                               address: { "topic" => "#{device.address['tele']}SENSOR", "json_path" => path.join(".") })
      end
    end

    # Caminhos dos campos numéricos (ex.: ["ENERGY", "Power"]), sem os do `skip`.
    def leaves(hash, prefix = [])
      hash.flat_map do |k, v|
        next leaves(v, prefix + [ k ]) if v.is_a?(Hash)

        v.is_a?(Numeric) && MAP["skip"].exclude?(k) ? [ prefix + [ k ] ] : []
      end
    end

    def point!(device, path, count, address:, **attrs)
      if (p = device.points.find { |x| x.address["json_path"] == path })
        p.update!(address: p.address.merge(address)) if p.address.slice(*address.keys) != address
      else
        device.points.create!(attrs.merge(site: device.site, address: address, key: Integrations.unique_key(device.site, device, attrs[:name])))
        count[:points] += 1
      end
    end
  end
end
