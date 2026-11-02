module HelperTypes
  # Limite (threshold do HA): liga quando a origem passa do limite. Só o
  # inferior = liga abaixo dele; só o superior = liga acima; os dois = liga
  # dentro da faixa. Histerese: para mudar, o valor precisa passar do limite
  # mais (ou menos) a histerese; no meio, fica como estava. Atributo
  # `position`: below (abaixo), above (acima) ou in_range (na faixa).
  class Threshold < Plugin
    describe key: "threshold", title: "Limite", icon: "exclamation-circle", capability: "onoff",
             description: "Liga quando um valor passa do limite (com histerese): umidade acima de 70%, tanque abaixo de 20%."
    fields %i[source lower upper hysteresis]
    texts "pt-BR" => { none: "Informe o limite inferior, o superior ou os dois.", order: "O limite inferior precisa ser menor que o superior.",
                       hyst: "A histerese não pode ser negativa.", between: "liga entre %{lower} e %{upper}", below: "liga abaixo de %{lower}",
                       above: "liga acima de %{upper}", hysteresis: "histerese %{n}" },
          en: { title: "Threshold", description: "Turns on when a value crosses a limit (with hysteresis): humidity above 70%, tank below 20%.",
                none: "Enter the lower limit, the upper limit or both.", order: "The lower limit must be less than the upper limit.",
                hyst: "Hysteresis can't be negative.", between: "on between %{lower} and %{upper}", below: "on below %{lower}",
                above: "on above %{upper}", hysteresis: "hysteresis %{n}" },
          es: { title: "Umbral", description: "Se enciende cuando un valor pasa del límite (con histéresis): humedad arriba de 70%, tanque abajo de 20%.",
                none: "Indica el límite inferior, el superior o los dos.", order: "El límite inferior debe ser menor que el superior.",
                hyst: "La histéresis no puede ser negativa.", between: "enciende entre %{lower} y %{upper}", below: "enciende abajo de %{lower}",
                above: "enciende arriba de %{upper}", hysteresis: "histéresis %{n}" }

    def self.assign(point, form)
      numeric_source!(point, form) or return
      a = point.address
      lower = form.key?("lower") ? number(form["lower"]) : a["lower"]
      upper = form.key?("upper") ? number(form["upper"]) : a["upper"]
      hyst = (form.key?("hysteresis") ? number(form["hysteresis"]) : a["hysteresis"]) || 0
      point.data_type = "bool"
      point.writable = false
      point.address = a.merge("lower" => lower, "upper" => upper, "hysteresis" => hyst)
      return point.errors.add(:base, text(:none)) if lower.nil? && upper.nil?
      return point.errors.add(:base, text(:order)) if lower && upper && lower >= upper

      point.errors.add(:base, text(:hyst)) if hyst.negative?
    end

    def self.sourced? = true

    def self.refresh!(point)
      v = reading(source(point))
      return point.report!(point.value, quality: "unavailable") if v.nil?

      a = point.address
      pos, on = position(v, a["lower"], a["upper"], a["hysteresis"].to_f)
      point.report_attrs!(point.attrs.to_h.merge("position" => pos)) if pos
      point.report!(on.nil? ? point.value == true : on)
    end

    # → [posição, ligado] (nil = dentro da histerese: fica como está).
    def self.position(v, lower, upper, h)
      below = ->(t) { v < t - h }
      above = ->(t) { v > t + h }
      if lower && upper
        return [ "below", false ] if below.(lower)
        return [ "above", false ] if above.(upper)

        below.(upper) && above.(lower) ? [ "in_range", true ] : [ nil, nil ]
      elsif lower
        below.(lower) ? [ "below", true ] : ([ "above", false ] if above.(lower)) || [ nil, nil ]
      else
        above.(upper) ? [ "above", true ] : ([ "below", false ] if below.(upper)) || [ nil, nil ]
      end
    end

    def self.summary(point)
      a = point.address
      msg = if a["lower"] && a["upper"] then text(:between, lower: fmt(a["lower"]), upper: fmt(a["upper"]))
      elsif a["lower"] then text(:below, lower: fmt(a["lower"]))
      else text(:above, upper: fmt(a["upper"]))
      end
      a["hysteresis"].to_f.positive? ? "#{msg} · #{text(:hysteresis, n: fmt(a['hysteresis']))}" : msg
    end

    def self.fmt(n) = n.to_f == n.to_i ? n.to_i.to_s : n.to_s
  end
end
