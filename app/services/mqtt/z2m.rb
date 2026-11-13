module Mqtt
  # Descoberta do zigbee2mqtt: a mensagem retida `<base>/bridge/devices` (lista
  # de aparelhos com `definition.exposes`) vira dispositivos `mqtt` e pontos
  # (exposes → capacidades). Idempotente: dispositivo por `ieee_address`,
  # ponto pela propriedade (`json_path`); renomear no z2m troca nome e tópicos.
  # O local é Z2M_SITE_ID ou, sem ele, o único local do servidor.
  module Z2m
    BINARY = { "occupancy" => "motion", "presence" => "motion", "vibration" => "motion", "contact" => "contact",
               "tamper" => "tamper", "water_leak" => "problem", "smoke" => "problem", "gas" => "problem",
               "carbon_monoxide" => "problem", "battery_low" => "problem" }.freeze
    NAMES = { "state" => "Liga/desliga", "brightness" => "Brilho", "temperature" => "Temperatura", "humidity" => "Umidade",
              "battery" => "Bateria", "occupancy" => "Movimento", "presence" => "Presença", "contact" => "Abertura",
              "power" => "Potência", "energy" => "Energia", "voltage" => "Tensão", "current" => "Corrente",
              "illuminance" => "Iluminância", "pressure" => "Pressão", "water_leak" => "Vazamento", "smoke" => "Fumaça",
              "tamper" => "Violação", "battery_low" => "Bateria fraca", "vibration" => "Vibração", "action" => "Ação",
              "color_temp" => "Temperatura de cor" }.freeze
    SKIP = %w[linkquality update update_available identify].freeze
    WRITE = 0b010

    module_function

    def base = ENV.fetch("Z2M_BASE_TOPIC", "zigbee2mqtt")
    def devices_topic = "#{base}/bridge/devices"

    PROTOCOL = "zigbee2mqtt".freeze
    ROLES = { "Coordinator" => "coordinator", "Router" => "router", "EndDevice" => "end_device" }.freeze

    def bridge_topic(name) = "#{base}/bridge/#{name}"

    # Descobridor do Mqtt::Listener (Pacote 1). Além do bridge/devices, a
    # ponte inteira (eventos de pareamento, info, estado e respostas) e a
    # disponibilidade dos aparelhos (docs/integracoes.md, "Zigbee").
    def topics = site ? [ devices_topic, bridge_topic("event"), bridge_topic("info"), bridge_topic("state"), bridge_topic("response/#"), "#{base}/+/availability" ] : []
    def handles?(topic) = topic.start_with?("#{base}/bridge/") || availability?(topic)
    def availability?(topic) = topic.start_with?("#{base}/") && topic.end_with?("/availability")

    def handle(topic, payload)
      s = site or return
      return discover!(s, payload) if topic == devices_topic
      return Bridge.availability(s, topic.delete_suffix("/availability"), payload) if availability?(topic)

      Bridge.receive(s, topic.delete_prefix("#{base}/bridge/"), payload)
    end

    # Ao conectar: os renomes que ficaram pendentes (broker fora na hora) vão de novo.
    def connected(_client) = (s = site) && Bridge.retry_renames(s)

    # Toda mensagem de aparelho (fora a descoberta): sinal (linkquality) e último visto.
    def observe(topic, payload) = Bridge.observe(topic, payload)

    def site
      return Site.find_by(id: ENV["Z2M_SITE_ID"]) if ENV["Z2M_SITE_ID"].present?

      Site.limit(2).to_a.then { |s| s.first if s.one? }
    end

    # → { devices: novos, points: novos }
    def discover!(site, payload)
      list = JSON.parse(payload)
      count = { devices: 0, points: 0 }
      ActsAsTenant.with_tenant(site.tenant) do
        Array(list).each do |d|
          next if d["type"] == "Coordinator" || d["disabled"] || !d["interview_completed"] || d.dig("definition", "exposes").blank?

          adopt(site, d, count)
        end
      end
      count
    end

    def adopt(site, d, count)
      device = site.devices.find_or_initialize_by(driver: "mqtt", external_id: d["ieee_address"])
      count[:devices] += 1 if device.new_record?
      topic = "#{base}/#{d['friendly_name']}"
      device.bridge_naming = true
      device.update!(name: name_for(device, d["friendly_name"]), manufacturer: d.dig("definition", "vendor"), model: d.dig("definition", "model"),
                     address: bridge_address(device, d, topic))
      Bridge.adopted(site, device, d)
      existing = device.points.index_by { |p| p.address["json_path"] }
      slug = d["friendly_name"].parameterize(separator: "_")
      Firmware.ensure_point!(device, address: { "topic" => topic, "json_path" => "update" }) if d.dig("definition", "supports_ota") # ondaA2 A18
      flatten(d["definition"]["exposes"]).each do |e|
        attrs = point_attrs(e) or next
        address = { "topic" => topic, "json_path" => e["property"] }.merge(attrs.delete(:address) || {})
        if (p = existing[e["property"]])
          p.update!(address: p.address.merge(address)) if p.address["topic"] != topic
        else
          device.points.create!(attrs.merge(site: site, address: address, key: "#{slug}.#{e['property'].parameterize(separator: '_')}"))
          count[:points] += 1
        end
      end
      battery = device.battery_point_id.nil? && device.points.find_by("points.address->>'json_path' = 'battery'")
      device.update_columns(battery_point_id: battery.id) if battery
    end

    # O nome daqui segue o friendly_name do z2m, menos enquanto um renome feito
    # aqui não chegou lá (`rename_to`): aí fica o daqui (Pairing.renamed).
    def name_for(device, friendly)
      pending = device.address.to_h["rename_to"]
      return friendly if pending.blank? || pending == friendly

      device.name.presence || friendly
    end

    def bridge_address(device, d, topic)
      a = device.address.to_h.merge("bridge" => PROTOCOL, "topic" => topic, "friendly_name" => d["friendly_name"])
      a.delete("rename_to") && a.delete("rename_at") if a["rename_to"] == d["friendly_name"]
      mesh = a["mesh"].to_h.merge("role" => ROLES[d["type"]], "power" => power(d["power_source"]), "power_source" => d["power_source"],
                                  "nwk" => d["network_address"]).compact
      a.merge("mesh" => mesh)
    end

    def power(source)
      return if source.blank?

      source.to_s.casecmp?("battery") ? "battery" : "mains"
    end

    # Tipos compostos (switch, light, lock, climate…) trazem os campos em `features`.
    def flatten(exposes) = Array(exposes).flat_map { |e| e["features"] ? flatten(e["features"]) : [ e ] }.select { |e| e["property"] }

    def point_attrs(e)
      return if SKIP.include?(e["name"])

      writable = (e["access"].to_i & WRITE).positive?
      name = [ NAMES[e["name"]] || e["label"].presence || e["name"].humanize, e["endpoint"] ].compact.join(" ")
      base = { name: name, writable: writable }
      case e["type"]
      when "binary" then binary(e, base, writable)
      when "numeric" then numeric(e, base, writable)
      when "enum"
        return base.merge(capability: "event", writable: false, history: "none") if e["name"] == "action"

        base.merge(capability: "enum", options: Array(e["values"]).map(&:to_s))
      when "text" then base.merge(capability: "text")
      end
    end

    def binary(e, base, writable)
      cap = writable ? "onoff" : BINARY[e["name"]]
      return unless cap

      # value_on do z2m já é o "ativo" (no contato, false = aberto), igual ao verdadeiro daqui.
      base.merge(capability: cap, device_class: e["name"], address: { "payload_on" => e["value_on"], "payload_off" => e["value_off"] })
    end

    def numeric(e, base, writable)
      if e["name"] == "brightness" && writable
        max = (e["value_max"] || 254).to_f
        return base.merge(capability: "dimmer", scale: (100 / max).round(6), min: 0, max: 100)
      end
      return base.merge(capability: "setpoint", unit: e["unit"], min: e["value_min"], max: e["value_max"], step: e["value_step"]) if writable

      base.merge(capability: "measure", unit: e["unit"], device_class: e["name"])
    end
  end
end
