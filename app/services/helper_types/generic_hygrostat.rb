module HelperTypes
  # Higrostato (generic_hygrostat do HA): a mesma regra com umidade.
  class GenericHygrostat < GenericThermostat
    MODES = %w[humidify dry].freeze
    ACTIONS = { "humidify" => "humidifying", "dry" => "drying" }.freeze

    fields %i[source switch mode tolerance target min_value max_value]
    describe key: "generic_hygrostat", title: "Higrostato", icon: "cloud-rain", capability: "setpoint",
             description: "Sensor de umidade + umidificador ou desumidificador (liga/desliga) viram um higrostato com a umidade desejada."
    texts "pt-BR" => { "form.source" => "Sensor de umidade", "form.switch" => "Umidificador ou desumidificador", "mode.humidify" => "Umidificar", "mode.dry" => "Desumidificar",
                       "hint.tolerance" => "Liga abaixo de desejado − tolerância e desliga acima de desejado + tolerância (umidificar)." },
          en: { title: "Hygrostat", description: "A humidity sensor + a humidifier or dehumidifier (on/off) become a hygrostat with a target humidity.",
                "form.source" => "Humidity sensor", "form.switch" => "Humidifier or dehumidifier", "mode.humidify" => "Humidify", "mode.dry" => "Dry",
                "hint.tolerance" => "Turns on below target − tolerance and off above target + tolerance (humidify)." },
          es: { title: "Higrostato", description: "Un sensor de humedad + un humidificador o deshumidificador (encendido/apagado) se vuelven un higrostato con la humedad deseada.",
                "form.source" => "Sensor de humedad", "form.switch" => "Humidificador o deshumidificador", "mode.humidify" => "Humidificar", "mode.dry" => "Deshumidificar",
                "hint.tolerance" => "Enciende abajo de deseado − tolerancia y apaga arriba de deseado + tolerancia (humidificar)." }

    def self.defaults = { "mode" => "humidify", "tolerance" => 3, "target" => 50, "min" => 20, "max" => 80 }
  end
end
