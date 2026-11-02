module Bridges
  # Ponte Matter (integ): o serviço `matter-bridge` (Node + matter.js, perfil
  # do compose desligado por padrão, pasta matter-bridge/) publica cada ponto
  # exposto como aparelho de uma ponte Matter; Apple Casa, Google Home e Alexa
  # pareiam pelo QR e comandam pela rede de casa. O estado vai no formato do
  # matter.js ({cluster => {atributo => valor}}) e cada atributo de `commands`
  # que o ecossistema muda volta como comando. A ordem de TYPES decide (o
  # primeiro que serve). Tipo novo = uma entrada aqui + a classe no
  # matter-bridge/index.js.
  class MatterBridge < Base
    describe key: "matter", title: "Matter", icon: "chip",
             description: "Apple Casa (Siri), Google Home e Alexa veem os pontos escolhidos como aparelhos Matter e comandam pela rede de casa, sem nuvem."
    texts "pt-BR" => { types: { door_lock: "Fechadura", window_covering: "Cortina", thermostat: "Termostato", extended_color_light: "Luz colorida", dimmable_light: "Luz com intensidade", on_off_light: "Luz", on_off_plug: "Tomada", contact_sensor: "Sensor de abertura", occupancy_sensor: "Sensor de presença", temperature_sensor: "Temperatura", humidity_sensor: "Umidade" } },
          en: { title: "Matter", description: "Apple Home (Siri), Google Home and Alexa see the chosen points as Matter devices and control them over your home network, no cloud.",
                types: { door_lock: "Lock", window_covering: "Cover", thermostat: "Thermostat", extended_color_light: "Color light", dimmable_light: "Dimmable light", on_off_light: "Light", on_off_plug: "Plug", contact_sensor: "Contact sensor", occupancy_sensor: "Occupancy sensor", temperature_sensor: "Temperature", humidity_sensor: "Humidity" } },
          es: { title: "Matter", description: "Apple Casa (Siri), Google Home y Alexa ven los puntos elegidos como aparatos Matter y los controlan por la red de casa, sin nube.",
                types: { door_lock: "Cerradura", window_covering: "Cortina", thermostat: "Termostato", extended_color_light: "Luz de color", dimmable_light: "Luz regulable", on_off_light: "Luz", on_off_plug: "Enchufe", contact_sensor: "Sensor de apertura", occupancy_sensor: "Sensor de presencia", temperature_sensor: "Temperatura", humidity_sensor: "Humedad" } }

    LIGHT = Alexa::SmartHome::Interfaces::PowerController::LIGHT
    COVER = /cortina|persiana|janela|toldo|blind|shade|curtain/i
    LEVEL = 254 # Matter: nível e cor vão de 0 a 254

    def self.level(pct) = (pct.to_f * LEVEL / 100).round.clamp(1, LEVEL)
    def self.pct_of(level) = (level.to_f * 100 / LEVEL).round
    def self.on?(p) = (s = sibling(p, "onoff")) ? s.value == true : true
    def self.onoff(p, v) = (s = sibling(p, "onoff")) ? [ v ? "on" : "off", nil, s ] : nil
    def self.temperature?(p) = p.device_class == "temperature" || p.unit.to_s.match?(/°?C\z/)
    def self.centi(v) = v.is_a?(Numeric) ? (v * 100).round : nil

    TYPES = {
      # Portão/fechadura (risco crítico: a exposição pede confirmação). Trancar = fechar.
      "door_lock" => {
        label: "Fechadura", applies: ->(p) { p.capability == "gate" },
        state: ->(_p, v) { { "doorLock" => { "lockState" => v.to_s == "closed" ? 1 : 2 } } },
        commands: { "doorLock.lockState" => ->(p, v) { (want = v.to_i == 1 ? "closed" : "open") == p.value ? nil : [ "pulse" ] } }
      },
      # Posição em % de cortina/persiana. Matter: 0 = aberta, 10000 = fechada.
      "window_covering" => {
        label: "Cortina", applies: ->(p) { p.capability == "setpoint" && p.unit.to_s.strip == "%" && (p.name.match?(COVER) || p.device.name.match?(COVER)) },
        state: lambda { |p, v|
          pos = (100 - to_pct(p, v)) * 100
          { "windowCovering" => { "currentPositionLiftPercent100ths" => pos, "targetPositionLiftPercent100ths" => pos } }
        },
        commands: { "windowCovering.targetPositionLiftPercent100ths" => ->(p, v) { [ "set", from_pct(p, 100 - (v.to_f / 100)) ] } }
      },
      "thermostat" => {
        label: "Termostato", applies: ->(p) { p.capability == "setpoint" && temperature?(p) },
        state: lambda { |p, v|
          temp = p.device.points.find { |s| s.capability == "measure" && s.device_class == "temperature" }&.value
          { "thermostat" => { "occupiedHeatingSetpoint" => centi(v), "occupiedCoolingSetpoint" => centi(v), "localTemperature" => centi(temp) }.compact }
        },
        commands: { "thermostat.occupiedHeatingSetpoint" => ->(_p, v) { [ "set", v.to_f / 100 ] },
                    "thermostat.occupiedCoolingSetpoint" => ->(_p, v) { [ "set", v.to_f / 100 ] } }
      },
      # Cor (Points::Color, hs + brilho "v"); liga/desliga pelo ponto onoff da mesma lâmpada.
      "extended_color_light" => {
        label: "Luz colorida", applies: ->(p) { p.capability == "color" },
        state: lambda { |p, v|
          c = v.is_a?(Hash) ? v : {}
          { "onOff" => { "onOff" => on?(p) }, "levelControl" => { "currentLevel" => level(c.fetch("v", 100)) },
            "colorControl" => { "currentHue" => (c["h"].to_f * LEVEL / 360).round, "currentSaturation" => level(c["s"].to_f) } }
        },
        commands: {
          "onOff.onOff" => ->(p, v) { onoff(p, v) },
          "levelControl.currentLevel" => ->(p, v) { [ "set", (p.value.is_a?(Hash) ? p.value : { "h" => 0, "s" => 0 }).slice("h", "s").merge("v" => pct_of(v)) ] },
          "colorControl.currentHue" => ->(p, v) { [ "set", (p.value.is_a?(Hash) ? p.value : {}).slice("s", "v").merge("h" => (v.to_f * 360 / LEVEL).round) ] },
          "colorControl.currentSaturation" => ->(p, v) { [ "set", { "h" => 0 }.merge((p.value.is_a?(Hash) ? p.value : {}).slice("h", "v")).merge("s" => pct_of(v)) ] }
        }
      },
      "dimmable_light" => {
        label: "Luz com intensidade", applies: ->(p) { p.capability == "dimmer" },
        state: ->(p, v) { { "onOff" => { "onOff" => sibling(p, "onoff") ? on?(p) : to_pct(p, v).positive? }, "levelControl" => { "currentLevel" => level(to_pct(p, v)) } } },
        commands: {
          "onOff.onOff" => ->(p, v) { onoff(p, v) || [ "set", v ? (p.max || 100) : (p.min || 0) ] },
          "levelControl.currentLevel" => ->(p, v) { [ "set", from_pct(p, pct_of(v)) ] }
        }
      },
      "on_off_light" => {
        label: "Luz", applies: ->(p) { p.capability == "onoff" && (p.name.match?(LIGHT) || p.device.name.match?(LIGHT) || p.icon == "light-bulb") },
        state: ->(_p, v) { { "onOff" => { "onOff" => v == true } } },
        commands: { "onOff.onOff" => ->(p, v) { v == p.value ? nil : [ v ? "on" : "off" ] } }
      },
      "on_off_plug" => {
        label: "Tomada", applies: ->(p) { p.capability == "onoff" },
        state: ->(_p, v) { { "onOff" => { "onOff" => v == true } } },
        commands: { "onOff.onOff" => ->(p, v) { v == p.value ? nil : [ v ? "on" : "off" ] } }
      },
      # Matter: stateValue verdadeiro = encostado (fechado); no MA verdadeiro = aberto.
      "contact_sensor" => { label: "Sensor de abertura", applies: ->(p) { p.capability == "contact" },
                            state: ->(_p, v) { { "booleanState" => { "stateValue" => v != true } } } },
      "occupancy_sensor" => { label: "Sensor de presença", applies: ->(p) { p.capability == "motion" },
                              state: ->(_p, v) { { "occupancySensing" => { "occupancy" => { "occupied" => v == true } } } } },
      "temperature_sensor" => { label: "Temperatura", applies: ->(p) { p.capability == "measure" && p.device_class == "temperature" },
                                state: ->(_p, v) { { "temperatureMeasurement" => { "measuredValue" => centi(v) } } } },
      "humidity_sensor" => { label: "Umidade", applies: ->(p) { p.capability == "measure" && p.device_class == "humidity" },
                             state: ->(_p, v) { { "relativeHumidityMeasurement" => { "measuredValue" => centi(v) } } } }
    }.freeze
  end
end
