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

    def self.assign(point, form)
      numeric_source!(point, form) or return
      a = point.address
      lower = form.key?("lower") ? number(form["lower"]) : a["lower"]
      upper = form.key?("upper") ? number(form["upper"]) : a["upper"]
      hyst = (form.key?("hysteresis") ? number(form["hysteresis"]) : a["hysteresis"]) || 0
      point.data_type = "bool"
      point.writable = false
      point.address = a.merge("lower" => lower, "upper" => upper, "hysteresis" => hyst)
      return point.errors.add(:base, "Informe o limite inferior, o superior ou os dois.") if lower.nil? && upper.nil?
      return point.errors.add(:base, "O limite inferior precisa ser menor que o superior.") if lower && upper && lower >= upper

      point.errors.add(:base, "A histerese não pode ser negativa.") if hyst.negative?
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
      text = if a["lower"] && a["upper"] then "liga entre #{fmt(a['lower'])} e #{fmt(a['upper'])}"
      elsif a["lower"] then "liga abaixo de #{fmt(a['lower'])}"
      else "liga acima de #{fmt(a['upper'])}"
      end
      a["hysteresis"].to_f.positive? ? "#{text} · histerese #{fmt(a['hysteresis'])}" : text
    end

    def self.fmt(n) = n.to_f == n.to_i ? n.to_i.to_s : n.to_s
  end
end
