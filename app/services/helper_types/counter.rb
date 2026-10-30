module HelperTypes
  # Contador (counter do HA): inicial, passo, mínimo e máximo; incrementar,
  # decrementar, zerar (volta ao inicial) e definir. Passar do limite fica no limite.
  class Counter < Plugin
    COMMANDS = %w[increment decrement reset set].freeze
    LABELS = { "increment" => "Incrementar", "decrement" => "Decrementar", "reset" => "Zerar (valor inicial)", "set" => "Definir valor" }.freeze

    describe key: "counter", title: "Contador", icon: "plus", capability: "counter",
             description: "Conta para cima e para baixo: quantas vezes a porta abriu, ciclos da bomba."
    fields %i[initial step min max]

    def self.assign(point, form)
      point.writable = true
      point.data_type = "integer"
      point.min = number(form["min"])&.to_i
      point.max = number(form["max"])&.to_i
      point.step = (number(form["step"]) || 1).to_i
      point.address = point.address.merge("initial" => (number(form["initial"]) || 0).to_i)
      point.errors.add(:step, "precisa ser maior que zero") unless point.step.positive?
      point.errors.add(:base, "O valor inicial precisa estar entre o mínimo e o máximo.") unless within?(point, point.address["initial"])
    end

    def self.within?(point, v) = (point.min.nil? || v >= point.min) && (point.max.nil? || v <= point.max)
    def self.initial_value(point) = point.address["initial"].to_i
    def self.commands(_point) = COMMANDS
    def self.command_labels = LABELS
    def self.actions(_point) = %w[decrement increment reset]

    def self.new_value(cmd)
      p = cmd.point
      v = case cmd.command
      when "increment" then p.value.to_i + p.step.to_i
      when "decrement" then p.value.to_i - p.step.to_i
      when "reset" then initial_value(p)
      else integer(cmd.value) || invalid!("Informe um número inteiro.")
      end
      v.clamp(p.min&.to_i || v, p.max&.to_i || v)
    end

    def self.integer(raw) = raw.is_a?(Numeric) ? (raw.to_i if raw == raw.to_i) : Integer(raw.to_s.strip, 10, exception: false)

    def self.summary(point)
      [ "começa em #{point.address['initial'].to_i}", "passo #{point.step.to_i}",
        ("de #{point.min.to_i}" if point.min), ("até #{point.max.to_i}" if point.max) ].compact.join(" · ")
    end
  end
end
