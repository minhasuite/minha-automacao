# ondaC1 (C4): descoberta MQTT no formato do Home Assistant, a mesma que
# OpenMQTTGateway, Frigate, ESPHome (modo MQTT), Shelly, Tasmota (HA),
# Theengs, rtl_433, Valetudo e centenas de firmwares publicam:
#   <prefixo>/<componente>/[<nó>/]<objeto>/config  → uma entidade
#   <prefixo>/device/<objeto>/config               → aparelho com `cmps`
# (prefixo `homeassistant`, ou MQTT_DISCOVERY_PREFIX). O JSON vem com as
# abreviações do HA (`stat_t`, `~`…), expandidas aqui. Cada componente é um
# plugin (`HaDiscovery::Components`, registro `COMPONENTS`) que diz os pontos;
# o Drivers::Mqtt lê e comanda pelos tópicos e templates (`value_template`,
# `command_template`, Jinja do HA). Aparelho = `device.identifiers` (um por
# aparelho, como no HA) com external_id "mqtt-ha:<id>". Payload vazio = a
# entidade saiu (ponto desativado). Disponibilidade (`availability`) liga e
# desliga o aparelho. Ao conectar, publica `<prefixo>/status online` (a
# "birth message" do HA) e os aparelhos reenviam a configuração.
# Melhor que o HA: o que já tem descoberta nativa aqui (zigbee2mqtt,
# Tasmota) não entra de novo pelo formato do HA (sem aparelho duplicado).
module Mqtt
  module HaDiscovery
    ABBR = {
      "act_t" => "action_topic", "act_tpl" => "action_template", "atype" => "automation_type",
      "avty" => "availability", "avty_mode" => "availability_mode", "avty_t" => "availability_topic", "avty_tpl" => "availability_template",
      "bri_cmd_t" => "brightness_command_topic", "bri_cmd_tpl" => "brightness_command_template", "bri_scl" => "brightness_scale",
      "bri_stat_t" => "brightness_state_topic", "bri_val_tpl" => "brightness_value_template",
      "cmd_off_tpl" => "command_off_template", "cmd_on_tpl" => "command_on_template", "cmd_t" => "command_topic", "cmd_tpl" => "command_template",
      "cmps" => "components", "curr_temp_t" => "current_temperature_topic", "curr_temp_tpl" => "current_temperature_template",
      "dev" => "device", "dev_cla" => "device_class", "e" => "encoding", "ent_cat" => "entity_category", "evt_typ" => "event_types",
      "exp_aft" => "expire_after", "frc_upd" => "force_update", "hs_cmd_t" => "hs_command_topic", "hs_stat_t" => "hs_state_topic",
      "hs_val_tpl" => "hs_value_template", "ic" => "icon", "json_attr_t" => "json_attributes_topic", "json_attr_tpl" => "json_attributes_template",
      "max_temp" => "max_temp", "min_temp" => "min_temp", "mode_cmd_t" => "mode_command_topic", "mode_cmd_tpl" => "mode_command_template",
      "mode_stat_t" => "mode_state_topic", "mode_stat_tpl" => "mode_state_template", "o" => "origin", "obj_id" => "object_id",
      "opt" => "optimistic", "ops" => "options", "p" => "platform", "pct_cmd_t" => "percentage_command_topic",
      "pct_cmd_tpl" => "percentage_command_template", "pct_stat_t" => "percentage_state_topic", "pct_val_tpl" => "percentage_value_template",
      "pl" => "payload", "pl_avail" => "payload_available", "pl_cls" => "payload_close", "pl_lock" => "payload_lock", "pl_not_avail" => "payload_not_available",
      "pl_off" => "payload_off", "pl_on" => "payload_on", "pl_open" => "payload_open", "pl_prs" => "payload_press", "pl_stop" => "payload_stop",
      "pl_unlk" => "payload_unlock", "pos_clsd" => "position_closed", "pos_open" => "position_open", "pos_t" => "position_topic",
      "pos_tpl" => "position_template", "qos" => "qos", "ret" => "retain", "rgb_cmd_t" => "rgb_command_topic", "rgb_stat_t" => "rgb_state_topic",
      "set_pos_t" => "set_position_topic", "set_pos_tpl" => "set_position_template", "stat_cla" => "state_class", "stat_clsd" => "state_closed",
      "stat_closing" => "state_closing", "stat_locked" => "state_locked", "stat_off" => "state_off", "stat_on" => "state_on",
      "stat_open" => "state_open", "stat_opening" => "state_opening", "stat_stopped" => "state_stopped", "stat_t" => "state_topic",
      "stat_tpl" => "state_template", "stat_unlocked" => "state_unlocked", "stat_val_tpl" => "state_value_template", "stype" => "subtype",
      "sug_dsp_prc" => "suggested_display_precision", "t" => "topic", "temp_cmd_t" => "temperature_command_topic",
      "temp_cmd_tpl" => "temperature_command_template", "temp_stat_t" => "temperature_state_topic", "temp_stat_tpl" => "temperature_state_template",
      "temp_unit" => "temperature_unit", "uniq_id" => "unique_id", "unit_of_meas" => "unit_of_measurement", "val_tpl" => "value_template",
      # resto: alarme, robô, umidificador, aquecedor e firmware
      "pl_arm_away" => "payload_arm_away", "pl_arm_home" => "payload_arm_home", "pl_arm_nite" => "payload_arm_night", "pl_arm_vacation" => "payload_arm_vacation",
      "pl_arm_custom_b" => "payload_arm_custom_bypass", "pl_disarm" => "payload_disarm", "pl_trig" => "payload_trigger", "set_fan_spd_t" => "set_fan_speed_topic",
      "fanspd_lst" => "fan_speed_list", "pl_strt" => "payload_start", "pl_paus" => "payload_pause", "pl_ret" => "payload_return_to_base", "pl_loc" => "payload_locate",
      "pl_inst" => "payload_install", "curr_hum_t" => "current_humidity_topic", "curr_hum_tpl" => "current_humidity_template",
      "hum_cmd_t" => "target_humidity_command_topic", "hum_cmd_tpl" => "target_humidity_command_template", "hum_stat_t" => "target_humidity_state_topic",
      "hum_state_tpl" => "target_humidity_state_template", "max_hum" => "max_humidity", "min_hum" => "min_humidity", "pow_cmd_t" => "power_command_topic"
    }.freeze
    DEVICE_ABBR = { "cns" => "connections", "ids" => "identifiers", "mf" => "manufacturer", "mdl" => "model", "mdl_id" => "model_id",
                    "hw" => "hw_version", "sw" => "sw_version", "sa" => "suggested_area", "sn" => "serial_number", "cu" => "configuration_url" }.freeze
    # Já têm descoberta nativa no MA (Mqtt::Z2m, Mqtt::Tasmota): não duplicar.
    SKIP_ORIGINS = /zigbee2mqtt|tasmota/i
    # Componentes que o MA entende (classe em HaDiscovery::Components). Novo = classe + nome aqui.
    COMPONENTS = %w[Sensor BinarySensor Switch Light Cover Number Select Button Fan Lock Text Event Scene Siren Valve Climate DeviceAutomation
                    AlarmControlPanel Camera Vacuum LawnMower Humidifier WaterHeater Update].freeze

    @availability = {} # tópico → external_ids dos aparelhos que dependem dele

    module_function

    def prefix = ENV.fetch("MQTT_DISCOVERY_PREFIX", "homeassistant")
    def components = COMPONENTS.to_h { |n| c = Components.const_get(n); [ c.key, c ] }

    # Descobridor do Mqtt::Listener.
    def topics = Z2m.site ? [ "#{prefix}/+/+/config", "#{prefix}/+/+/+/config", *availability_topics ] : []
    def handles?(topic) = (topic.start_with?("#{prefix}/") && topic.end_with?("/config")) || @availability.key?(topic)

    # Birth message: os aparelhos que seguem o HA reenviam a configuração.
    def connected(client) = Z2m.site && client.publish("#{prefix}/status", "online", true)

    def availability_topics
      @availability = {}
      ActsAsTenant.without_tenant do
        Device.where(driver: "mqtt", removed_at: nil).where("external_id LIKE 'mqtt-ha:%'").pluck(:external_id, Arel.sql("address->'availability'")).each do |id, list|
          Array(list.is_a?(String) ? JSON.parse(list) : list).each { |a| (@availability[a["topic"]] ||= Set.new) << id }
        end
      end
      @availability.keys
    end

    def handle(topic, payload)
      site = Z2m.site or return
      return availability!(site, topic, payload) if @availability.key?(topic) && !topic.end_with?("/config")

      parts = topic.delete_prefix("#{prefix}/").delete_suffix("/config").split("/")
      component = parts.first
      object = parts.drop(1).join("/")
      ActsAsTenant.with_tenant(site.tenant) do
        next remove!(site, component, object) if payload.to_s.strip.empty?

        cfg = expand(JSON.parse(payload))
        next unless cfg.is_a?(Hash)

        component == "device" ? device_config!(site, object, cfg) : entity!(site, component, object, cfg)
      end
    rescue JSON::ParserError
      nil
    end

    # Formato de aparelho (HA 2024.11): `cmps` com cada entidade e o `p` (componente).
    def device_config!(site, object, cfg)
      shared = cfg.except("components", "device", "origin")
      count = { devices: 0, points: 0 }
      cfg["components"].to_h.each do |id, c|
        c = expand(c)
        next remove!(site, c["platform"], "#{object}/#{id}") if c.keys == [ "platform" ] # só o `p` = entidade saiu

        entity!(site, c["platform"], "#{object}/#{id}", shared.merge(c).merge("device" => cfg["device"], "origin" => cfg["origin"]), count)
      end
      count
    end

    def entity!(site, component, object, cfg, count = { devices: 0, points: 0 })
      klass = components[component] or return count # componente que o MA ainda não entende: fica de fora
      return count if skip?(cfg)

      device = device!(site, cfg, object, count)
      ident = "#{component}/#{object}"
      klass.points(cfg).each do |attrs|
        attrs = attrs.deep_stringify_keys
        sub = attrs.delete("sub")
        address = attrs.delete("address").compact.merge("discovery" => [ ident, sub ].compact.join("#"))
        point!(device, address, attrs, count)
      end
      count
    end

    def skip?(cfg) = cfg.dig("origin", "name").to_s.match?(SKIP_ORIGINS) || Array(cfg.dig("device", "identifiers")).any? { |i| i.to_s.match?(/\Azigbee2mqtt_/) }

    def device!(site, cfg, object, count)
      d = cfg["device"].to_h
      id = Array(d["identifiers"]).first.presence || Array(Array(d["connections"]).first).last.presence || cfg["unique_id"].presence || object
      device = site.devices.find_or_initialize_by(driver: "mqtt", external_id: "mqtt-ha:#{id}")
      count[:devices] += 1 if device.new_record?
      avail = availability(cfg)
      device.assign_attributes(name: d["name"].presence || device.name.presence || cfg["name"].presence || id.to_s, manufacturer: d["manufacturer"],
                               model: d["model"], firmware: d["sw_version"].presence || device.firmware,
                               address: device.address.merge("availability" => (Array(device.address["availability"]) + avail).uniq { |a| a["topic"] }))
      device.area ||= site.areas.find_by("lower(name) = ?", d["suggested_area"].to_s.downcase) if d["suggested_area"].present?
      device.save! if device.changed?
      avail.each { |a| (@availability[a["topic"]] ||= Set.new) << device.external_id }
      device
    end

    def availability(cfg)
      list = cfg["availability"].presence || (cfg["availability_topic"] && [ cfg.slice("availability_topic", "payload_available", "payload_not_available", "availability_template").transform_keys { |k| k.sub("availability_", "") } ])
      Array(list).filter_map do |a|
        a = expand(a)
        next unless (topic = a["topic"]).present?

        { "topic" => topic, "on" => a["payload_available"] || "online", "off" => a["payload_not_available"] || "offline", "template" => a["value_template"] || a["template"] }.compact
      end
    end

    def availability!(site, topic, payload)
      ActsAsTenant.with_tenant(site.tenant) do
        site.devices.where(driver: "mqtt", external_id: @availability[topic].to_a).includes(:points).find_each do |device|
          a = Array(device.address["availability"]).find { |x| x["topic"] == topic } or next
          v = a["template"] ? render(a["template"], payload) : payload.to_s
          next unless [ a["on"], a["off"] ].include?(v)

          on = v == a["on"]
          device.update_columns(status: on ? "online" : "offline", last_seen_at: Time.current)
          device.points.each do |p|
            next if p.disabled || (on ? p.quality != "unavailable" : p.quality == "unavailable")

            p.report!(p.value, quality: on ? "good" : "unavailable")
          end
        end
      end
    end

    def point!(device, address, attrs, count)
      p = device.points.find { |x| x.address["discovery"] == address["discovery"] }
      if p
        p.update!(address: p.address.merge(address), disabled: false) if p.address.slice(*address.keys) != address || p.disabled
      else
        device.points.create!(attrs.merge("site" => device.site, "address" => address, "key" => Integrations.unique_key(device.site, device, attrs["name"])))
        count[:points] += 1
      end
    end

    # Retido vazio: a entidade saiu (o ponto fica desativado, nada é apagado).
    def remove!(site, component, object)
      ident = "#{component}/#{object}"
      site.points.joins(:device).where(devices: { driver: "mqtt" })
          .where("points.address->>'discovery' = ? OR points.address->>'discovery' LIKE ?", ident, "#{Point.sanitize_sql_like(ident)}#%")
          .find_each { |p| p.update!(disabled: true) }
    end

    # Abreviações do HA + `~` (tópico base) → chaves completas.
    def expand(cfg)
      return cfg unless cfg.is_a?(Hash)

      out = cfg.to_h { |k, v| [ ABBR.fetch(k, k), v ] }
      out["device"] = out["device"].to_h.to_h { |k, v| [ DEVICE_ABBR.fetch(k, k), v ] } if out["device"].is_a?(Hash)
      out["origin"] = out["origin"].to_h.to_h { |k, v| [ { "sw" => "sw_version", "url" => "support_url" }.fetch(k, k), v ] } if out["origin"].is_a?(Hash)
      base = out.delete("~")
      return out unless base

      tilde = ->(v) { v.start_with?("~") ? base + v[1..] : (v.end_with?("~") ? v[0..-2] + base : v) }
      out = out.to_h { |k, v| [ k, v.is_a?(String) && (k == "topic" || k.end_with?("_topic")) ? tilde.call(v) : v ] }
      out["availability"] = Array(out["availability"]).map { |a| a.is_a?(Hash) ? expand(a).then { |e| e.merge("topic" => tilde.call(e["topic"].to_s)) } : a } if out["availability"]
      out
    end

    # --- templates (value_template, command_template) ------------------------
    # Jinja do HA → Liquid: `| float(0)` vira `| float: 0`; o resto (`if/else`,
    # `is_state`…) passa pelo tradutor da ondaA1 (Automations::HaTemplates).
    module Filters
      def float(v, d = 0.0) = Float(v.to_s, exception: false) || d
      def int(v, d = 0) = (f = Float(v.to_s, exception: false)) ? f.to_i : d
      def lower(v) = v.to_s.downcase
      def upper(v) = v.to_s.upcase
      def tojson(v) = v.to_json
      def to_json(v) = v.to_json
    end

    def render(src, value, extra = {})
      json = value.is_a?(String) ? (JSON.parse(value) rescue nil) : value # rubocop:disable Style/RescueModifier
      tpl = src.to_s.gsub(/\|\s*(\w+)\(([^()]*)\)/) { "| #{$1}: #{$2}" }
      tpl = Automations::HaTemplates.text(tpl, nil) || tpl unless Automations::HaTemplates.liquid_ok?(tpl)
      Liquid::Template.parse(tpl).render({ "value" => value, "value_json" => json }.merge(extra.stringify_keys), filters: [ Filters ]).strip
    rescue Liquid::Error
      nil
    end
  end
end
