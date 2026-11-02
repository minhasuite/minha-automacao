module HelperTypes
  # Texto (input_text do HA): tamanho mínimo e máximo, padrão (regex) e modo senha.
  class Text < Plugin
    MAX = 255

    describe key: "text", title: "Texto", icon: "document-text", capability: "text",
             description: "Um texto livre, com tamanho e padrão opcionais: recado, código do portão."
    fields %i[min max pattern password]
    texts "pt-BR" => { max: "precisa ser de 1 a %{max}", pattern: "Padrão inválido (expressão regular).", hidden: "Oculto",
                       size: "O texto precisa ter de %{min} a %{max} caracteres.", mismatch: "Texto fora do padrão.",
                       chars: "%{min} a %{max} caracteres", password: "senha" },
          en: { title: "Text", description: "Free text, with optional length and pattern: a note, the gate code.",
                max: "must be from 1 to %{max}", pattern: "Invalid pattern (regular expression).", hidden: "Hidden",
                size: "The text must be %{min} to %{max} characters long.", mismatch: "The text doesn't match the pattern.",
                chars: "%{min} to %{max} characters", password: "password" },
          es: { title: "Texto", description: "Un texto libre, con largo y patrón opcionales: una nota, el código del portón.",
                max: "debe ser de 1 a %{max}", pattern: "Patrón no válido (expresión regular).", hidden: "Oculto",
                size: "El texto debe tener de %{min} a %{max} caracteres.", mismatch: "El texto no coincide con el patrón.",
                chars: "%{min} a %{max} caracteres", password: "contraseña" }

    def self.assign(point, form)
      point.writable = true
      point.min = number(form["min"]) || 0
      point.max = number(form["max"]) || MAX
      pattern = form["pattern"].to_s.strip.presence
      point.address = point.address.merge("pattern" => pattern, "password" => ActiveModel::Type::Boolean.new.cast(form["password"]) || false).compact
      point.address.delete("pattern") unless pattern
      point.errors.add(:max, text(:max, max: MAX)) unless point.max.between?(1, MAX)
      regex(pattern) if pattern
    rescue RegexpError
      point.errors.add(:base, text(:pattern))
    end

    # Regex com tempo limite (o padrão é escrito por quem cadastra).
    def self.regex(pattern) = Regexp.new("\\A(?:#{pattern})\\z", timeout: 0.1)

    def self.initial_value(_point) = ""
    def self.value_text(point) = (text(:hidden) if point.address["password"] && point.value.present?)

    def self.new_value(cmd)
      s = cmd.by_capability.to_s
      p = cmd.point
      invalid!(text(:size, min: p.min.to_i, max: p.max.to_i)) unless s.length.between?(p.min.to_i, p.max.to_i)
      invalid!(text(:mismatch)) if p.address["pattern"] && !regex(p.address["pattern"]).match?(s)
      s
    rescue Regexp::TimeoutError
      invalid!(text(:mismatch))
    end

    def self.summary(point) = [ text(:chars, min: point.min.to_i, max: point.max.to_i), (text(:password) if point.address["password"]) ].compact.join(" · ")
  end
end
