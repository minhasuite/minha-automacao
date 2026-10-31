module Alexa
  module SmartHome
    # Interfaces Smart Home v3 como plugins (F9), no padrão de
    # Integrations::PLUGINS: cada classe diz a que alvo serve (`applies?`,
    # pela capacidade do ponto ou cena), o pedaço da descoberta
    # (`capability`), o estado (`properties`) e o que cada diretiva vira
    # (`handle` → [comando, valor] do Points::Command, ou :scene). Nada de
    # `case` por capacidade fora daqui. Interface nova = classe + linha em PLUGINS.
    module Interfaces
      PLUGINS = %w[PowerController BrightnessController PercentageController ThermostatController RangeController
                   LockController SceneController].freeze

      def self.plugins = PLUGINS.map { |n| const_get(n) }
      def self.for(target) = plugins.select { |i| i.applies?(target) }
      def self.[](namespace) = plugins.find { |i| i.namespace == namespace }

      class Base
        class << self
          attr_reader :namespace, :category, :label

          # `label`: o que a pessoa pode pedir, em português, para a tela.
          def describe(namespace:, category:, label: nil)
            @namespace = namespace
            @category = category
            @label = label || namespace.delete_prefix("Alexa.")
          end

          def applies?(_target) = false
          def properties(_point, _value) = []
          def handle(_name, _payload, _point) = raise(Error.new("INVALID_DIRECTIVE", "Diretiva não suportada."))
          def category_for(_target) = category

          def capability(_target) = interface(properties: names)
          def names = []

          def interface(**extra) = { "type" => "AlexaInterface", "interface" => namespace, "version" => "3" }.merge(extra.stringify_keys)

          def props(*list) = { "supported" => list.map { |n| { "name" => n } }, "proactivelyReported" => false, "retrievable" => true }

          def point?(t) = t.is_a?(Point)
          def number(v) = v.is_a?(Numeric) ? v : nil

          # Escala do ponto ↔ 0–100 %.
          def to_pct(p, v)
            min, max = (p.min || 0).to_f, (p.max || 100).to_f
            max > min && v.is_a?(Numeric) ? (((v - min) / (max - min)) * 100).round.clamp(0, 100) : 0
          end

          def from_pct(p, pct)
            raise Error.new("VALUE_OUT_OF_RANGE", "Use de 0 a 100.") unless pct.is_a?(Numeric) && pct.between?(0, 100)

            min, max = (p.min || 0).to_f, (p.max || 100).to_f
            v = min + ((max - min) * pct / 100.0)
            p.data_type == "integer" ? v.round : v.round(2)
          end
        end
      end

      class PowerController < Base
        describe namespace: "Alexa.PowerController", category: "SWITCH", label: "ligar e desligar"
        LIGHT = /luz|l[aâ]mpada|ilumina|spot|pendente|abajur|led|monitor/i

        def self.applies?(t) = point?(t) && t.capability == "onoff"
        def self.category_for(t) = t.name.match?(LIGHT) || t.icon == "light-bulb" ? "LIGHT" : "SWITCH"
        def self.capability(_t) = interface(properties: props("powerState"))
        def self.properties(_p, v) = [ [ "powerState", v ? "ON" : "OFF" ] ]

        def self.handle(name, _payload, _p)
          { "TurnOn" => [ "on" ], "TurnOff" => [ "off" ] }.fetch(name) { super }
        end
      end

      class BrightnessController < Base
        describe namespace: "Alexa.BrightnessController", category: "LIGHT", label: "brilho"

        def self.applies?(t) = point?(t) && t.capability == "dimmer"
        def self.capability(_t) = interface(properties: props("brightness"))
        def self.properties(p, v) = [ [ "brightness", to_pct(p, v) ] ]

        def self.handle(name, payload, p)
          case name
          when "SetBrightness" then [ "set", from_pct(p, number(payload["brightness"])) ]
          when "AdjustBrightness" then [ "set", from_pct(p, (to_pct(p, p.value) + number(payload["brightnessDelta"]).to_i).clamp(0, 100)) ]
          else super
          end
        end
      end

      # Número em % (ajuste genérico com unidade %).
      class PercentageController < Base
        describe namespace: "Alexa.PercentageController", category: "OTHER", label: "porcentagem"

        def self.applies?(t) = point?(t) && t.capability == "setpoint" && t.unit.to_s.strip == "%"
        def self.capability(_t) = interface(properties: props("percentage"))
        def self.properties(p, v) = [ [ "percentage", to_pct(p, v) ] ]

        def self.handle(name, payload, p)
          case name
          when "SetPercentage" then [ "set", from_pct(p, number(payload["percentage"])) ]
          when "AdjustPercentage" then [ "set", from_pct(p, (to_pct(p, p.value) + number(payload["percentageDelta"]).to_i).clamp(0, 100)) ]
          else super
          end
        end
      end

      # Temperatura alvo (setpoint em °C): só o alvo, sem modos (básico).
      class ThermostatController < Base
        describe namespace: "Alexa.ThermostatController", category: "THERMOSTAT", label: "temperatura"

        def self.applies?(t) = point?(t) && t.capability == "setpoint" && (t.device_class == "temperature" || t.unit.to_s.include?("C"))
        def self.capability(_t) = interface(properties: props("targetSetpoint"), configuration: { "supportsScheduling" => false })
        def self.properties(_p, v) = [ [ "targetSetpoint", { "value" => v.to_f, "scale" => "CELSIUS" } ] ]

        def self.handle(name, payload, p)
          case name
          when "SetTargetTemperature" then [ "set", celsius(p, payload["targetSetpoint"]) ]
          when "AdjustTargetTemperature" then [ "set", celsius(p, payload["targetSetpointDelta"], base: p.value.to_f) ]
          else super
          end
        end

        def self.celsius(p, sp, base: 0)
          v = number(sp.to_h["value"]) or raise Error.new("INVALID_VALUE", "Temperatura inválida.")
          v = (v - 32) * 5 / 9.0 if sp["scale"] == "FAHRENHEIT" && base.zero?
          v = (base + v).round(1)
          raise Error.new("TEMPERATURE_VALUE_OUT_OF_RANGE", "Fora da faixa.") if (p.min && v < p.min) || (p.max && v > p.max)

          v
        end
      end

      # Número qualquer (helper Número, ajuste): faixa do ponto.
      class RangeController < Base
        describe namespace: "Alexa.RangeController", category: "OTHER", label: "valor"
        INSTANCE = "Ponto.Valor".freeze

        def self.applies?(t) = point?(t) && t.capability == "setpoint" && !PercentageController.applies?(t) && !ThermostatController.applies?(t)

        def self.capability(t)
          range = { "minimumValue" => (t.min || 0).to_f, "maximumValue" => (t.max || 100).to_f, "precision" => (t.step || 1).to_f }
          interface(instance: INSTANCE, properties: props("rangeValue"),
                    capabilityResources: { "friendlyNames" => [ { "@type" => "text", "value" => { "text" => "valor", "locale" => "pt-BR" } } ] },
                    configuration: { "supportedRange" => range })
        end

        def self.properties(_p, v) = [ [ "rangeValue", v.to_f, INSTANCE ] ]

        def self.handle(name, payload, p)
          case name
          when "SetRangeValue" then [ "set", in_range(p, number(payload["rangeValue"])) ]
          when "AdjustRangeValue" then [ "set", in_range(p, p.value.to_f + number(payload["rangeValueDelta"]).to_f) ]
          else super
          end
        end

        def self.in_range(p, v)
          raise Error.new("VALUE_OUT_OF_RANGE", "Fora da faixa.") if v.nil? || (p.min && v < p.min) || (p.max && v > p.max)

          v
        end
      end

      # Portão/fechadura (risco crítico): trancar = fechar. A Alexa pede o
      # código de voz para destrancar quando a pessoa liga isso no app dela.
      class LockController < Base
        describe namespace: "Alexa.LockController", category: "SMARTLOCK", label: "trancar"
        STATES = { "closed" => "LOCKED", "open" => "UNLOCKED", "opening" => "UNLOCKED" }.freeze

        def self.applies?(t) = point?(t) && t.capability == "gate"
        def self.capability(_t) = interface(properties: props("lockState"))
        def self.properties(_p, v) = [ [ "lockState", STATES.fetch(v.to_s, "JAMMED") ] ]

        def self.handle(name, _payload, p)
          want = { "Lock" => "closed", "Unlock" => "open" }.fetch(name) { return super }
          p.value == want ? [ nil, want ] : [ "pulse" ]
        end
      end

      # Cena do local ou script (ponto `script`, comando run).
      class SceneController < Base
        describe namespace: "Alexa.SceneController", category: "SCENE_TRIGGER", label: "ativar"

        def self.applies?(t) = t.is_a?(Scene) || (point?(t) && t.capability == "script")
        def self.capability(_t) = interface(supportsDeactivation: false)

        def self.handle(name, _payload, _t)
          name == "Activate" ? [ :activate ] : super
        end
      end
    end
  end
end
