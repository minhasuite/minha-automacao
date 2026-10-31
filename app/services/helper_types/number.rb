module HelperTypes
  # Número (input_number do HA): mínimo, máximo, passo, unidade, slider ou caixa.
  class Number < Plugin
    MODES = { "slider" => "Barra deslizante", "box" => "Caixa de número" }.freeze

    describe key: "number", title: "Número", icon: "calculator", capability: "setpoint",
             description: "Um valor ajustável com mínimo, máximo e passo: temperatura alvo, minutos de rega."
    fields %i[min max step unit mode]

    def self.assign(point, form)
      point.writable = true
      point.data_type = "decimal"
      point.min = number(form["min"]) || 0
      point.max = number(form["max"]) || 100
      point.step = number(form["step"]) || 1
      point.unit = form["unit"]
      point.address = point.address.merge("mode" => form["mode"].presence_in(MODES.keys) || "slider")
      point.errors.add(:step, "precisa ser maior que zero") unless point.step.positive?
    end

    def self.initial_value(point) = point.min.to_f

    def self.new_value(cmd)
      v = cmd.by_capability
      p = cmd.point
      return v if p.step.nil? || ((v.to_d - p.min.to_d) % p.step.to_d).zero?

      invalid!("Use passos de #{fmt(p.step)}.")
    end

    def self.summary(point) = "#{fmt(point.min)} a #{fmt(point.max)}#{" #{point.unit}" if point.unit}, passo #{fmt(point.step)} · #{MODES[point.address['mode']]&.downcase}"
    def self.fmt(n) = n.to_d.to_s("F").delete_suffix(".0")
  end
end
