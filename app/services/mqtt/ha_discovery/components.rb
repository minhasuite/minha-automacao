module Mqtt
  module HaDiscovery
    # Componentes da descoberta do HA (ondaC1, C4) como plugins: cada classe
    # diz o componente (`describe key:`) e transforma a configuração já
    # expandida em pontos (`points(cfg)` → [{sub, name, capability, …,
    # address}]). `address` usa só o que o Drivers::Mqtt entende: `topic`,
    # `json_path`, `value_template`, `value_map`, `command_topic`,
    # `command_json_path`, `command_template`, `payload_on/off`,
    # `state_on/off`, `payload_map`, `payload_press`, `retain`.
    module Components
      class Base
        class << self
          attr_reader :key

          def describe(key:) = @key = key
          def points(_cfg) = []

          def name(cfg, fallback) = cfg["name"].presence || fallback
          def label(cfg, fallback) = Z2m::NAMES[cfg["device_class"].to_s] || cfg["device_class"].to_s.humanize.presence || fallback

          def state(cfg, topic = "state_topic", template = "value_template")
            { "topic" => cfg[topic], "value_template" => cfg[template] }
          end

          def command(cfg, topic = "command_topic", template = "command_template")
            { "command_topic" => cfg[topic], "command_template" => cfg[template], "retain" => (true if cfg["retain"]) }
          end

          # HA: escala do aparelho (0–255, 0–1000…) ↔ 0–100 daqui.
          def scale_of(max) = (100.0 / (max.presence || 100).to_f).round(6)
        end
      end

      class Sensor < Base
        describe key: "sensor"
        NUMERIC = %w[temperature humidity battery power energy voltage current illuminance pressure carbon_dioxide pm25 pm10 signal_strength
                     distance speed volume water gas weight moisture frequency power_factor apparent_power irradiance].freeze

        def self.points(c)
          base = { name: name(c, label(c, "Sensor")), unit: c["unit_of_measurement"], device_class: c["device_class"], state_class: c["state_class"],
                   writable: false, address: state(c) }
          return [ base.merge(capability: "enum", options: Array(c["options"]).map(&:to_s)) ] if c["device_class"] == "enum" && Array(c["options"]).any?

          numeric = c["unit_of_measurement"].present? || c["state_class"].present? || NUMERIC.include?(c["device_class"])
          [ base.merge(capability: numeric ? "measure" : "text") ]
        end
      end

      class BinarySensor < Base
        describe key: "binary_sensor"
        CLASSES = { "motion" => "motion", "occupancy" => "motion", "presence" => "motion", "moving" => "motion", "vibration" => "motion",
                    "door" => "contact", "window" => "contact", "opening" => "contact", "garage_door" => "contact", "lock" => "contact",
                    "tamper" => "tamper" }.freeze

        def self.points(c)
          [ { name: name(c, label(c, "Sensor")), capability: CLASSES.fetch(c["device_class"].to_s, "problem"), device_class: c["device_class"], writable: false,
              address: state(c).merge("payload_on" => c.fetch("payload_on", "ON"), "payload_off" => c.fetch("payload_off", "OFF")) } ]
        end
      end

      class Switch < Base
        describe key: "switch"
        def self.capability = "onoff"
        def self.risk = "normal"

        def self.points(c)
          on, off = c.fetch("payload_on", "ON"), c.fetch("payload_off", "OFF")
          [ { name: name(c, "Liga/desliga"), capability: capability, risk: risk,
              address: state(c).merge(command(c)).merge("payload_on" => on, "payload_off" => off, "state_on" => c.fetch("state_on", on), "state_off" => c.fetch("state_off", off)) } ]
        end
      end

      class Siren < Switch
        describe key: "siren"
        def self.risk = "sensitive"
      end

      class Light < Base
        describe key: "light"

        def self.points(c)
          return json(c) if c["schema"] == "json"

          on, off = c.fetch("payload_on", "ON"), c.fetch("payload_off", "OFF")
          list = [ { sub: "state", name: name(c, "Luz"), capability: "onoff", icon: "light-bulb",
                     address: state(c, "state_topic", "state_value_template").merge(command(c)).merge("payload_on" => on, "payload_off" => off) } ]
          if c["brightness_command_topic"].present?
            list << { sub: "brightness", name: "Brilho", capability: "dimmer", min: 0, max: 100, scale: scale_of(c["brightness_scale"] || 255),
                      address: state(c, "brightness_state_topic", "brightness_value_template").merge(command(c, "brightness_command_topic", "brightness_command_template")) }
          end
          list
        end

        # Esquema JSON: um tópico de estado e um de comando, com `state` e `brightness` no JSON.
        def self.json(c)
          base = { "topic" => c["state_topic"], "command_topic" => c["command_topic"] }
          list = [ { sub: "state", name: name(c, "Luz"), capability: "onoff", icon: "light-bulb",
                     address: base.merge("json_path" => "state", "command_json_path" => "state", "payload_on" => "ON", "payload_off" => "OFF") } ]
          if c["brightness"] || Array(c["supported_color_modes"]).intersect?(%w[brightness hs rgb xy color_temp])
            list << { sub: "brightness", name: "Brilho", capability: "dimmer", min: 0, max: 100, scale: scale_of(c["brightness_scale"] || 255),
                      address: base.merge("json_path" => "brightness", "command_json_path" => "brightness") }
          end
          list
        end
      end

      class Cover < Base
        describe key: "cover"
        STATES = %w[open closed opening closing stopped].freeze

        def self.points(c)
          list = []
          if c["set_position_topic"].present? || c["position_topic"].present?
            list << { sub: "position", name: name(c, "Posição"), capability: "setpoint", unit: "%", min: 0, max: 100, step: 1,
                      scale: scale_of(c.fetch("position_open", 100) - c.fetch("position_closed", 0)), offset: 0, writable: c["set_position_topic"].present?,
                      address: state(c, "position_topic", "position_template").merge(command(c, "set_position_topic", "set_position_template")) }
          end
          if c["command_topic"].present?
            map = { "open" => c.fetch("payload_open", "OPEN"), "close" => c.fetch("payload_close", "CLOSE"), "stop" => c.fetch("payload_stop", "STOP") }.compact
            list << { sub: "command", name: "Comando", capability: "enum", options: map.keys, address: { "command_topic" => c["command_topic"], "payload_map" => map } }
          end
          if c["state_topic"].present?
            map = STATES.to_h { |s| [ c.fetch("state_#{s}", s), s ] }
            list << { sub: "state", name: "Estado", capability: "enum", options: STATES, writable: false, address: state(c).merge("value_map" => map) }
          end
          list
        end
      end

      class Number < Base
        describe key: "number"

        def self.points(c)
          [ { name: name(c, label(c, "Número")), capability: "setpoint", unit: c["unit_of_measurement"], device_class: c["device_class"],
              min: c.fetch("min", 1), max: c.fetch("max", 100), step: c.fetch("step", 1), address: state(c).merge(command(c)) } ]
        end
      end

      class Select < Base
        describe key: "select"
        def self.points(c) = [ { name: name(c, "Opção"), capability: "enum", options: Array(c["options"]).map(&:to_s), address: state(c).merge(command(c)) } ]
      end

      class Text < Base
        describe key: "text"
        def self.points(c) = [ { name: name(c, "Texto"), capability: "text", address: state(c).merge(command(c)) } ]
      end

      class Button < Base
        describe key: "button"
        def self.points(c) = [ { name: name(c, "Botão"), capability: "command", address: command(c).merge("payload_press" => c.fetch("payload_press", "PRESS")) } ]
      end

      class Scene < Base
        describe key: "scene"
        def self.points(c) = [ { name: name(c, "Cena"), capability: "command", address: command(c).merge("payload_press" => c.fetch("payload_on", "ON")) } ]
      end

      class Fan < Base
        describe key: "fan"

        def self.points(c)
          on, off = c.fetch("payload_on", "ON"), c.fetch("payload_off", "OFF")
          list = [ { sub: "state", name: name(c, "Ventilador"), capability: "onoff", address: state(c).merge(command(c)).merge("payload_on" => on, "payload_off" => off) } ]
          if c["percentage_command_topic"].present?
            list << { sub: "percentage", name: "Velocidade", capability: "setpoint", unit: "%", min: 0, max: 100, step: 1,
                      scale: scale_of(c.fetch("speed_range_max", 100)), address: state(c, "percentage_state_topic", "percentage_value_template")
                        .merge(command(c, "percentage_command_topic", "percentage_command_template")) }
          end
          list
        end
      end

      # Fechadura: crítica (só com confirmação nas exposições e o papel × risco de sempre).
      class Lock < Base
        describe key: "lock"

        def self.points(c)
          read = { c.fetch("state_locked", "LOCKED") => "locked", c.fetch("state_unlocked", "UNLOCKED") => "unlocked" }
          write = { "locked" => c.fetch("payload_lock", "LOCK"), "unlocked" => c.fetch("payload_unlock", "UNLOCK") }
          [ { name: name(c, "Fechadura"), capability: "enum", options: %w[locked unlocked], risk: "critical", icon: "lock-closed",
              address: state(c).merge(command(c)).merge("value_map" => read, "payload_map" => write) } ]
        end
      end

      # Válvula (irrigação, água): sensível.
      class Valve < Base
        describe key: "valve"

        def self.points(c)
          if c["reports_position"]
            return [ { name: name(c, "Abertura"), capability: "setpoint", unit: "%", min: 0, max: 100, step: 1, risk: "sensitive",
                       scale: scale_of(c.fetch("position_open", 100)), address: state(c).merge(command(c)) } ]
          end

          open, close = c.fetch("payload_open", "OPEN"), c.fetch("payload_close", "CLOSE")
          [ { name: name(c, "Válvula"), capability: "onoff", risk: "sensitive",
              address: state(c).merge(command(c)).merge("payload_on" => open, "payload_off" => close,
                                                        "state_on" => c.fetch("state_open", "open"), "state_off" => c.fetch("state_closed", "closed")) } ]
        end
      end

      class Climate < Base
        describe key: "climate"

        def self.points(c)
          list = []
          if c["mode_command_topic"].present? || c["mode_state_topic"].present?
            list << { sub: "mode", name: "Modo", capability: "enum", options: Array(c["modes"].presence || %w[auto off cool heat dry fan_only]).map(&:to_s),
                      writable: c["mode_command_topic"].present?,
                      address: state(c, "mode_state_topic", "mode_state_template").merge(command(c, "mode_command_topic", "mode_command_template")) }
          end
          if c["temperature_command_topic"].present?
            list << { sub: "target", name: "Temperatura alvo", capability: "setpoint", unit: "°C", device_class: "temperature",
                      min: c.fetch("min_temp", 7), max: c.fetch("max_temp", 35), step: c.fetch("temp_step", c.fetch("precision", 0.5)),
                      address: state(c, "temperature_state_topic", "temperature_state_template").merge(command(c, "temperature_command_topic", "temperature_command_template")) }
          end
          if c["current_temperature_topic"].present?
            list << { sub: "current", name: "Temperatura", capability: "measure", unit: "°C", device_class: "temperature", state_class: "measurement", writable: false,
                      address: state(c, "current_temperature_topic", "current_temperature_template") }
          end
          list
        end
      end

      # Evento (botão sem estado): conta a cada mensagem.
      class Event < Base
        describe key: "event"
        def self.points(c) = [ { name: name(c, "Evento"), capability: "event", history: "none", writable: false, address: state(c) } ]
      end

      # Gatilho de aparelho (controle remoto, botão): vira evento do ponto (gatilho "Aparelho fez algo").
      class DeviceAutomation < Base
        describe key: "device_automation"

        def self.points(c)
          [ { sub: "#{c['type']}_#{c['subtype']}", name: [ c["subtype"], c["type"] ].compact_blank.join(" ").humanize.presence || "Ação",
              capability: "event", history: "none", writable: false, address: { "topic" => c["topic"], "value_template" => c["value_template"] } } ]
        end
      end
    end
  end
end
