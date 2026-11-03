module Bridges
  # Ponte HomeKit (ondaC1, C5; o HomeKit Bridge do HA): o serviço
  # `homekit-bridge` (Node + hap-nodejs, perfil `homekit` do compose,
  # desligado) publica cada ponto exposto como acessório HAP para o app Casa
  # da Apple, sem Matter (iPhone/HomePod antigos) e com o portão como portão
  # de garagem de verdade. O estado vai no formato do hap-nodejs
  # ({Serviço => {Característica => valor}}); cada característica de
  # `commands` que o Casa muda volta como comando. A ordem de TYPES decide.
  class HomekitBridge < Base
    describe key: "homekit", title: "HomeKit", icon: "home",
             description: "O app Casa da Apple (Siri, iPhone, iPad, HomePod, Apple Watch) vê os pontos escolhidos como acessórios HomeKit, pela rede de casa e sem Matter."
    texts "pt-BR" => { types: { garage_door: "Portão de garagem", window_covering: "Cortina", thermostat: "Termostato", color_light: "Luz colorida", dimmable_light: "Luz com intensidade",
                                light: "Luz", switch: "Interruptor", contact_sensor: "Sensor de abertura", motion_sensor: "Sensor de movimento", temperature_sensor: "Temperatura",
                                humidity_sensor: "Umidade" },
                       pair_help: "No iPhone: app Casa → Adicionar acessório → leia o QR ou digite o código. Pareie num aparelho só; os outros moradores entram pelo convite da Casa.",
                       start_html: "Ligue o serviço no servidor da casa (<code>docker compose --profile homekit up -d homekit-bridge</code>) com a chave abaixo em <code>HOMEKIT_BRIDGE_KEY</code>. O QR aparece aqui em segundos." },
          en: { title: "HomeKit", description: "Apple's Home app (Siri, iPhone, iPad, HomePod, Apple Watch) sees the chosen points as HomeKit accessories, over your home network and without Matter.",
                types: { garage_door: "Garage door", window_covering: "Cover", thermostat: "Thermostat", color_light: "Color light", dimmable_light: "Dimmable light", light: "Light",
                         switch: "Switch", contact_sensor: "Contact sensor", motion_sensor: "Motion sensor", temperature_sensor: "Temperature", humidity_sensor: "Humidity" },
                pair_help: "On the iPhone: Home app → Add Accessory → scan the QR or type the code. Pair on one device only; other residents join through the Home invite.",
                start_html: "Start the service on the home server (<code>docker compose --profile homekit up -d homekit-bridge</code>) with the key below in <code>HOMEKIT_BRIDGE_KEY</code>. The QR shows up here in seconds." },
          es: { title: "HomeKit", description: "La app Casa de Apple (Siri, iPhone, iPad, HomePod, Apple Watch) ve los puntos elegidos como accesorios HomeKit, por la red de casa y sin Matter.",
                types: { garage_door: "Portón de garaje", window_covering: "Cortina", thermostat: "Termostato", color_light: "Luz de color", dimmable_light: "Luz regulable", light: "Luz",
                         switch: "Interruptor", contact_sensor: "Sensor de apertura", motion_sensor: "Sensor de movimiento", temperature_sensor: "Temperatura", humidity_sensor: "Humedad" },
                pair_help: "En el iPhone: app Casa → Agregar accesorio → lee el QR o escribe el código. Vincula en un solo aparato; los demás residentes entran por la invitación de Casa.",
                start_html: "Inicia el servicio en el servidor de casa (<code>docker compose --profile homekit up -d homekit-bridge</code>) con la clave de abajo en <code>HOMEKIT_BRIDGE_KEY</code>. El QR aparece aquí en segundos." }

    M = MatterBridge
    # HAP: portão 0 = aberto, 1 = fechado; contato 0 = encostado, 1 = aberto.
    def self.door(v) = v.to_s == "closed" ? 1 : 0
    def self.onoff(p, v) = (s = sibling(p, "onoff")) ? [ v ? "on" : "off", nil, s ] : nil
    def self.color(p) = p.value.is_a?(Hash) ? p.value : {}

    TYPES = {
      "garage_door" => {
        applies: ->(p) { p.capability == "gate" },
        state: ->(_p, v) { { "GarageDoorOpener" => { "CurrentDoorState" => door(v), "TargetDoorState" => door(v), "ObstructionDetected" => false } } },
        commands: { "GarageDoorOpener.TargetDoorState" => ->(p, v) { (v.to_i == 1 ? "closed" : "open") == p.value ? nil : [ "pulse" ] } }
      },
      "window_covering" => {
        applies: ->(p) { M::TYPES["window_covering"][:applies].call(p) },
        state: ->(p, v) { { "WindowCovering" => { "CurrentPosition" => to_pct(p, v), "TargetPosition" => to_pct(p, v), "PositionState" => 2 } } },
        commands: { "WindowCovering.TargetPosition" => ->(p, v) { [ "set", from_pct(p, v) ] } }
      },
      "thermostat" => {
        applies: ->(p) { p.capability == "setpoint" && M.temperature?(p) },
        state: lambda { |p, v|
          temp = p.device.points.find { |s| s.capability == "measure" && s.device_class == "temperature" }&.value
          { "Thermostat" => { "CurrentTemperature" => (temp || v).to_f, "TargetTemperature" => v.to_f, "CurrentHeatingCoolingState" => 0, "TargetHeatingCoolingState" => 3,
                              "TemperatureDisplayUnits" => 0 } }
        },
        commands: { "Thermostat.TargetTemperature" => ->(_p, v) { [ "set", v.to_f ] } }
      },
      "color_light" => {
        applies: ->(p) { p.capability == "color" },
        state: ->(p, _v) { { "Lightbulb" => { "On" => M.on?(p), "Brightness" => color(p).fetch("v", 100).to_i, "Hue" => color(p)["h"].to_i, "Saturation" => color(p)["s"].to_i } } },
        commands: {
          "Lightbulb.On" => ->(p, v) { onoff(p, v) },
          "Lightbulb.Brightness" => ->(p, v) { [ "set", { "h" => 0, "s" => 0 }.merge(color(p).slice("h", "s")).merge("v" => v.to_i) ] },
          "Lightbulb.Hue" => ->(p, v) { [ "set", { "s" => 100 }.merge(color(p).slice("s", "v")).merge("h" => v.to_i) ] },
          "Lightbulb.Saturation" => ->(p, v) { [ "set", { "h" => 0 }.merge(color(p).slice("h", "v")).merge("s" => v.to_i) ] }
        }
      },
      "dimmable_light" => {
        applies: ->(p) { p.capability == "dimmer" },
        state: ->(p, v) { { "Lightbulb" => { "On" => sibling(p, "onoff") ? M.on?(p) : to_pct(p, v).positive?, "Brightness" => to_pct(p, v) } } },
        commands: { "Lightbulb.On" => ->(p, v) { onoff(p, v) || [ "set", v ? (p.max || 100) : (p.min || 0) ] },
                    "Lightbulb.Brightness" => ->(p, v) { [ "set", from_pct(p, v) ] } }
      },
      "light" => {
        applies: ->(p) { M::TYPES["on_off_light"][:applies].call(p) },
        state: ->(_p, v) { { "Lightbulb" => { "On" => v == true } } },
        commands: { "Lightbulb.On" => ->(p, v) { v == p.value ? nil : [ v ? "on" : "off" ] } }
      },
      "switch" => {
        applies: ->(p) { p.capability == "onoff" },
        state: ->(_p, v) { { "Switch" => { "On" => v == true } } },
        commands: { "Switch.On" => ->(p, v) { v == p.value ? nil : [ v ? "on" : "off" ] } }
      },
      "contact_sensor" => { applies: ->(p) { p.capability == "contact" }, state: ->(_p, v) { { "ContactSensor" => { "ContactSensorState" => v == true ? 1 : 0 } } } },
      "motion_sensor" => { applies: ->(p) { p.capability == "motion" }, state: ->(_p, v) { { "MotionSensor" => { "MotionDetected" => v == true } } } },
      "temperature_sensor" => { applies: ->(p) { p.capability == "measure" && p.device_class == "temperature" },
                                state: ->(_p, v) { { "TemperatureSensor" => { "CurrentTemperature" => v.to_f } } } },
      "humidity_sensor" => { applies: ->(p) { p.capability == "measure" && p.device_class == "humidity" },
                             state: ->(_p, v) { { "HumiditySensor" => { "CurrentRelativeHumidity" => v.to_f } } } }
    }.freeze

    # HAP: PIN "123-45-678" como está (o da Matter é 1234-567-8901).
    def self.format_code(code) = code.to_s
  end
end
