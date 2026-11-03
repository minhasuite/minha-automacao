module GoogleHome
  # Traits do Google Home (ondaC1, C6) como plugins, no padrão das interfaces
  # da Alexa: cada classe diz a que ponto serve (`applies?`), o tipo de
  # aparelho (`type`), os atributos do SYNC, o estado do QUERY e o que cada
  # comando do EXECUTE vira (`execute` → [comando, valor(, outro ponto)] do
  # Points::Command, ou nil = já está assim). Trait novo = classe + nome em PLUGINS.
  module Traits
    PLUGINS = %w[OnOff Brightness ColorSetting OpenClose TemperatureSetting TemperatureControl HumiditySetting OccupancySensing Scene].freeze
    PREFIX = "action.devices.traits.".freeze
    COMMAND = "action.devices.commands.".freeze

    def self.plugins = PLUGINS.map { |n| const_get(n) }
    def self.for(point) = plugins.select { |t| t.applies?(point) }

    class Base
      class << self
        attr_reader :trait, :device_type

        def describe(trait:, type:)
          @trait = "#{PREFIX}#{trait}"
          @device_type = "action.devices.types.#{type}"
        end

        def applies?(_point) = false
        def type(_point) = device_type
        def attributes(_point) = {}
        def state(_point, _value) = {}
        def commands = []
        def execute(_command, _params, _point) = raise(Error.new("notSupported", "Comando não suportado."))

        def to_pct(p, v) = Bridges::Base.to_pct(p, v)
        def from_pct(p, pct) = Bridges::Base.from_pct(p, pct)
        def sibling(p, capability) = Bridges::Base.sibling(p, capability)
        def cover?(p) = p.capability == "setpoint" && p.unit.to_s.strip == "%" && (p.name.match?(Bridges::MatterBridge::COVER) || p.device.name.match?(Bridges::MatterBridge::COVER))
        def light?(p) = p.name.match?(Alexa::SmartHome::Interfaces::PowerController::LIGHT) || p.device.name.match?(Alexa::SmartHome::Interfaces::PowerController::LIGHT) || p.icon == "light-bulb"
      end
    end

    class OnOff < Base
      describe trait: "OnOff", type: "SWITCH"
      def self.applies?(p) = p.capability == "onoff"
      def self.type(p) = light?(p) ? "action.devices.types.LIGHT" : (p.name.match?(/tomada|plug|outlet/i) ? "action.devices.types.OUTLET" : device_type)
      def self.state(_p, v) = { "on" => v == true }
      def self.commands = %w[OnOff]
      def self.execute(_c, params, p) = params["on"] == p.value ? nil : [ params["on"] ? "on" : "off" ]
    end

    class Brightness < Base
      describe trait: "Brightness", type: "LIGHT"
      def self.applies?(p) = p.capability == "dimmer"

      def self.state(p, v)
        on = (s = sibling(p, "onoff")) ? s.value == true : to_pct(p, v).positive?
        { "on" => on, "brightness" => to_pct(p, v) }
      end

      def self.commands = %w[BrightnessAbsolute OnOff]

      def self.execute(command, params, p)
        return [ "set", from_pct(p, params["brightness"].to_i.clamp(0, 100)) ] if command == "BrightnessAbsolute"

        (s = sibling(p, "onoff")) ? [ params["on"] ? "on" : "off", nil, s ] : [ "set", params["on"] ? (p.max || 100) : (p.min || 0) ]
      end
    end

    # Cor HSV (Points::Color: h 0–360, s e v 0–100; Google: s e v de 0 a 1).
    class ColorSetting < Base
      describe trait: "ColorSetting", type: "LIGHT"
      def self.applies?(p) = p.capability == "color"
      def self.attributes(_p) = { "colorModel" => "hsv" }

      def self.state(p, v)
        c = v.is_a?(Hash) ? v : {}
        { "on" => (s = sibling(p, "onoff")) ? s.value == true : true,
          "color" => { "spectrumHsv" => { "hue" => c["h"].to_f, "saturation" => (c["s"].to_f / 100).round(3), "value" => (c.fetch("v", 100).to_f / 100).round(3) } } }
      end

      def self.commands = %w[ColorAbsolute OnOff]

      def self.execute(command, params, p)
        return (s = sibling(p, "onoff")) && [ params["on"] ? "on" : "off", nil, s ] if command == "OnOff"

        hsv = params.dig("color", "spectrumHSV") || params.dig("color", "spectrumHsv") or raise Error.new("valueOutOfRange", "Cor sem HSV.")
        [ "set", { "h" => hsv["hue"].to_f.round, "s" => (hsv["saturation"].to_f * 100).round, "v" => (hsv.fetch("value", 1).to_f * 100).round } ]
      end
    end

    # Cortina (posição %), portão (só abre/fecha, com desafio) e abertura (só leitura).
    class OpenClose < Base
      describe trait: "OpenClose", type: "BLINDS"
      def self.applies?(p) = cover?(p) || p.capability.in?(%w[gate contact])
      def self.type(p) = { "gate" => "action.devices.types.GARAGE", "contact" => "action.devices.types.DOOR" }.fetch(p.capability, device_type)

      def self.attributes(p)
        return { "queryOnlyOpenClose" => true, "discreteOnlyOpenClose" => true } if p.capability == "contact"

        p.capability == "gate" ? { "discreteOnlyOpenClose" => true } : {}
      end

      def self.state(p, v)
        pct = case p.capability
        when "gate" then v.to_s == "closed" ? 0 : 100
        when "contact" then v == true ? 100 : 0
        else to_pct(p, v)
        end
        { "openPercent" => pct }
      end

      def self.commands = %w[OpenClose]

      def self.execute(_c, params, p)
        pct = params["openPercent"].to_i.clamp(0, 100)
        return [ "set", from_pct(p, pct) ] if cover?(p)

        open = pct.positive?
        open == (p.value.to_s != "closed") ? nil : [ "pulse" ]
      end
    end

    class TemperatureSetting < Base
      describe trait: "TemperatureSetting", type: "THERMOSTAT"
      def self.applies?(p) = p.capability == "setpoint" && Bridges::MatterBridge.temperature?(p)

      def self.attributes(p)
        { "availableThermostatModes" => %w[heatcool], "thermostatTemperatureUnit" => "C",
          "thermostatTemperatureRange" => { "minThresholdCelsius" => (p.min || 10).to_f, "maxThresholdCelsius" => (p.max || 32).to_f } }
      end

      def self.state(p, v)
        ambient = p.device.points.find { |s| s.capability == "measure" && s.device_class == "temperature" }&.value
        { "thermostatMode" => "heatcool", "thermostatTemperatureSetpoint" => v.to_f, "thermostatTemperatureAmbient" => ambient&.to_f }.compact
      end

      def self.commands = %w[ThermostatTemperatureSetpoint ThermostatSetMode]

      def self.execute(command, params, _p)
        return nil if command == "ThermostatSetMode"

        [ "set", params["thermostatTemperatureSetpoint"].to_f ]
      end
    end

    class TemperatureControl < Base
      describe trait: "TemperatureControl", type: "SENSOR"
      def self.applies?(p) = p.capability == "measure" && p.device_class == "temperature"
      def self.attributes(_p) = { "queryOnlyTemperatureControl" => true, "temperatureUnitForUX" => "C", "temperatureRange" => { "minThresholdCelsius" => -40, "maxThresholdCelsius" => 85 } }
      def self.state(_p, v) = { "temperatureAmbientCelsius" => v.to_f }
    end

    class HumiditySetting < Base
      describe trait: "HumiditySetting", type: "SENSOR"
      def self.applies?(p) = p.capability == "measure" && p.device_class == "humidity"
      def self.attributes(_p) = { "queryOnlyHumiditySetting" => true }
      def self.state(_p, v) = { "humidityAmbientPercent" => v.to_f.round }
    end

    class OccupancySensing < Base
      describe trait: "OccupancySensing", type: "SENSOR"
      def self.applies?(p) = p.capability == "motion"

      def self.attributes(_p)
        { "occupancySensorConfiguration" => [ { "occupancySensorType" => "PIR", "occupiedToUnoccupiedDelaySec" => 10, "unoccupiedToOccupiedDelaySec" => 0,
                                                "unoccupiedToOccupiedEventThreshold" => 1 } ] }
      end

      def self.state(_p, v) = { "occupancy" => v == true ? "OCCUPIED" : "UNOCCUPIED" }
    end

    class Scene < Base
      describe trait: "Scene", type: "SCENE"
      def self.applies?(p) = p.capability == "script"
      def self.attributes(_p) = { "sceneReversible" => false }
      def self.commands = %w[ActivateScene]
      def self.execute(_c, _params, _p) = [ "run" ]
    end
  end
end
