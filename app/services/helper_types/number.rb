module HelperTypes
  # Número (input_number do HA): mínimo, máximo, passo, unidade, slider ou caixa.
  class Number < Plugin
    MODES = { "slider" => "Barra deslizante", "box" => "Caixa de número" }.freeze

    describe key: "number", title: "Número", icon: "calculator", capability: "setpoint",
             description: "Um valor ajustável com mínimo, máximo e passo: temperatura alvo, minutos de rega."
    fields %i[min max step unit mode]
    texts "pt-BR" => { modes: MODES, step: "precisa ser maior que zero", steps: "Use passos de %{step}.", summary: "%{min} a %{max}%{unit}, passo %{step} · %{mode}" },
          en: { title: "Number", description: "An adjustable value with minimum, maximum and step: target temperature, watering minutes.",
                modes: { slider: "Slider", box: "Number box" }, step: "must be greater than zero", steps: "Use steps of %{step}.",
                summary: "%{min} to %{max}%{unit}, step %{step} · %{mode}" },
          es: { title: "Número", description: "Un valor ajustable con mínimo, máximo y paso: temperatura objetivo, minutos de riego.",
                modes: { slider: "Barra deslizante", box: "Caja de número" }, step: "debe ser mayor que cero", steps: "Usa pasos de %{step}.",
                summary: "%{min} a %{max}%{unit}, paso %{step} · %{mode}" }

    def self.modes = labels(:modes, MODES)

    def self.assign(point, form)
      point.writable = true
      point.data_type = "decimal"
      point.min = number(form["min"]) || 0
      point.max = number(form["max"]) || 100
      point.step = number(form["step"]) || 1
      point.unit = form["unit"]
      point.address = point.address.merge("mode" => form["mode"].presence_in(MODES.keys) || "slider")
      point.errors.add(:step, text(:step)) unless point.step.positive?
    end

    def self.initial_value(point) = point.min.to_f

    def self.new_value(cmd)
      v = cmd.by_capability
      p = cmd.point
      return v if p.step.nil? || ((v.to_d - p.min.to_d) % p.step.to_d).zero?

      invalid!(text(:steps, step: fmt(p.step)))
    end

    def self.summary(point) = text(:summary, min: fmt(point.min), max: fmt(point.max), unit: (" #{point.unit}" if point.unit).to_s, step: fmt(point.step),
                                                mode: modes[point.address["mode"]]&.downcase.to_s)
    def self.fmt(n) = n.to_d.to_s("F").delete_suffix(".0")
  end
end
