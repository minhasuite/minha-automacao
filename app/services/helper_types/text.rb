module HelperTypes
  # Texto (input_text do HA): tamanho mínimo e máximo, padrão (regex) e modo senha.
  class Text < Plugin
    MAX = 255

    describe key: "text", title: "Texto", icon: "document-text", capability: "text",
             description: "Um texto livre, com tamanho e padrão opcionais: recado, código do portão."
    fields %i[min max pattern password]

    def self.assign(point, form)
      point.writable = true
      point.min = number(form["min"]) || 0
      point.max = number(form["max"]) || MAX
      pattern = form["pattern"].to_s.strip.presence
      point.address = point.address.merge("pattern" => pattern, "password" => ActiveModel::Type::Boolean.new.cast(form["password"]) || false).compact
      point.address.delete("pattern") unless pattern
      point.errors.add(:max, "precisa ser de 1 a #{MAX}") unless point.max.between?(1, MAX)
      regex(pattern) if pattern
    rescue RegexpError
      point.errors.add(:base, "Padrão inválido (expressão regular).")
    end

    # Regex com tempo limite (o padrão é escrito por quem cadastra).
    def self.regex(pattern) = Regexp.new("\\A(?:#{pattern})\\z", timeout: 0.1)

    def self.initial_value(_point) = ""
    def self.value_text(point) = ("Oculto" if point.address["password"] && point.value.present?)

    def self.new_value(cmd)
      s = cmd.by_capability.to_s
      p = cmd.point
      invalid!("O texto precisa ter de #{p.min.to_i} a #{p.max.to_i} caracteres.") unless s.length.between?(p.min.to_i, p.max.to_i)
      invalid!("Texto fora do padrão.") if p.address["pattern"] && !regex(p.address["pattern"]).match?(s)
      s
    rescue Regexp::TimeoutError
      invalid!("Texto fora do padrão.")
    end

    def self.summary(point) = [ "#{point.min.to_i} a #{point.max.to_i} caracteres", ("senha" if point.address["password"]) ].compact.join(" · ")
  end
end
