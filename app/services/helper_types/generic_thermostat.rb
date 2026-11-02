module HelperTypes
  # Termostato (generic_thermostat do HA, ondaA1 A10): um sensor de
  # temperatura e um liga/desliga (aquecedor ou ar) viram um termostato. O
  # valor é a temperatura desejada (ajustável no painel, na voz e na
  # automação); liga quando passa da tolerância para o lado errado e desliga
  # do outro lado. Atributos: `current` (a leitura) e `action`
  # (heating/cooling/idle). Higrostato = a mesma regra com umidade.
  class GenericThermostat < Plugin
    describe key: "generic_thermostat", title: "Termostato", icon: "sun", capability: "setpoint",
             description: "Sensor de temperatura + aquecedor ou ar (liga/desliga) viram um termostato com a temperatura desejada."
    fields %i[source switch mode tolerance target min_value max_value]
    MODES = %w[heat cool].freeze
    ACTIONS = { "heat" => "heating", "cool" => "cooling" }.freeze
    texts "pt-BR" => { "form.source" => "Sensor de temperatura", "form.switch" => "Aquecedor ou ar (liga/desliga)", "form.mode" => "Modo",
                       "form.tolerance" => "Tolerância", "form.target" => "Desejado (inicial)", "form.min_value" => "Mínimo", "form.max_value" => "Máximo",
                       "mode.heat" => "Aquecer", "mode.cool" => "Resfriar", "hint.tolerance" => "Liga abaixo de desejado − tolerância e desliga acima de desejado + tolerância (aquecer).",
                       pick: "Escolha o sensor e um liga/desliga que receba comando.", range: "Desejado entre o mínimo e o máximo.", summary: "%{mode} com %{switch}, ±%{tol}" },
          en: { title: "Thermostat", description: "A temperature sensor + a heater or AC (on/off) become a thermostat with a target temperature.",
                "form.source" => "Temperature sensor", "form.switch" => "Heater or AC (on/off)", "form.mode" => "Mode", "form.tolerance" => "Tolerance",
                "form.target" => "Target (initial)", "form.min_value" => "Minimum", "form.max_value" => "Maximum", "mode.heat" => "Heat", "mode.cool" => "Cool",
                "hint.tolerance" => "Turns on below target − tolerance and off above target + tolerance (heat).",
                pick: "Choose the sensor and an on/off point that accepts commands.", range: "Target between the minimum and the maximum.", summary: "%{mode} with %{switch}, ±%{tol}" },
          es: { title: "Termostato", description: "Un sensor de temperatura + un calefactor o aire (encendido/apagado) se vuelven un termostato con la temperatura deseada.",
                "form.source" => "Sensor de temperatura", "form.switch" => "Calefactor o aire (encendido/apagado)", "form.mode" => "Modo", "form.tolerance" => "Tolerancia",
                "form.target" => "Deseado (inicial)", "form.min_value" => "Mínimo", "form.max_value" => "Máximo", "mode.heat" => "Calentar", "mode.cool" => "Enfriar",
                "hint.tolerance" => "Enciende abajo de deseado − tolerancia y apaga arriba de deseado + tolerancia (calentar).",
                pick: "Elige el sensor y un encendido/apagado que reciba comandos.", range: "Deseado entre el mínimo y el máximo.", summary: "%{mode} con %{switch}, ±%{tol}" }

    def self.defaults = { "mode" => "heat", "tolerance" => 0.5, "target" => 22, "min" => 7, "max" => 35 }

    def self.form_spec
      [ [ :source, :source, { index: 0 } ], [ :switch, :point, { index: 1, filter: ->(p) { p.capability == "onoff" && p.writable } } ],
        [ :mode, :select, { choices: -> { self::MODES.index_with { |k| text("mode.#{k}") } }, value: ->(p) { p.address["mode"] || defaults["mode"] } } ],
        [ :tolerance, :number, { value: ->(p) { p.address["tolerance"] || defaults["tolerance"] } } ],
        [ :target, :number, { value: ->(p) { p.value || defaults["target"] } } ],
        [ :min_value, :number, { value: ->(p) { p.min&.to_f || defaults["min"] } } ], [ :max_value, :number, { value: ->(p) { p.max&.to_f || defaults["max"] } } ] ]
    end

    def self.assign(point, form)
      a = point.address
      sensor = point.site.points.find_by(id: form["source"].presence || a.dig("sources", 0))
      switch = point.site.points.find_by(id: form["switch"].presence || a.dig("sources", 1))
      return point.errors.add(:base, text(:pick)) unless sensor&.numeric? && switch&.capability == "onoff" && switch.writable && [ sensor.id, switch.id ].exclude?(point.id)

      mode = form.fetch("mode", a["mode"]).to_s.presence_in(self::MODES) || defaults["mode"]
      tol = (form.key?("tolerance") ? number(form["tolerance"]) : a["tolerance"]) || defaults["tolerance"]
      point.min = (form.key?("min_value") ? number(form["min_value"]) : point.min) || defaults["min"]
      point.max = (form.key?("max_value") ? number(form["max_value"]) : point.max) || defaults["max"]
      point.step ||= 0.5
      point.unit = sensor.unit
      point.data_type = "decimal"
      point.writable = true
      target = number(form["target"]) if form.key?("target")
      point.address = a.merge("sources" => [ sensor.id, switch.id ], "mode" => mode, "tolerance" => tol.abs, "target" => target || a["target"] || defaults["target"])
      point.errors.add(:base, text(:range)) unless point.address["target"].to_f.between?(point.min.to_f, point.max.to_f)
    end

    def self.sourced? = true
    def self.drives_points? = true
    def self.initial_value(point) = point.address["target"].to_f
    def self.new_value(cmd) = cmd.by_capability

    def self.execute(point, command, value)
      point.report!(Points::Command.new(point, command, value).new_value)
      control!(point)
    end

    def self.refresh!(point)
      point.report!(point.address["target"].to_f) if point.value.nil?
      control!(point)
    end

    # Liga/desliga a saída pela leitura e pelo desejado (com a tolerância).
    def self.control!(point)
      sensor, switch = point.address["sources"].map { |id| point.site.points.find_by(id: id) }
      cur = reading(sensor)
      return point.report_attrs!(point.attrs.to_h.merge("current" => nil, "action" => "idle")) if cur.nil? || switch.nil? || !point.value.is_a?(Numeric)

      want = decide(point.address["mode"], cur, point.value.to_f, point.address["tolerance"].to_f, switch.value == true)
      Points::Command.call(switch, want ? "on" : "off", nil, source: "automation", user: nil) if want != (switch.value == true)
      point.report_attrs!(point.attrs.to_h.merge("current" => cur, "action" => want ? self::ACTIONS[point.address["mode"]] : "idle"))
    end

    # Aquecer (ou umidificar): liga abaixo de alvo − tol, desliga acima de alvo + tol; no meio, fica.
    def self.decide(mode, cur, target, tol, on_now)
      low = %w[heat humidify].include?(mode)
      return true if low ? cur <= target - tol : cur >= target + tol
      return false if low ? cur >= target + tol : cur <= target - tol

      on_now
    end

    def self.summary(point)
      switch = point.site.points.find_by(id: point.address.dig("sources", 1))
      text(:summary, mode: text("mode.#{point.address['mode']}"), switch: switch&.name.to_s, tol: point.address["tolerance"])
    end
  end
end
