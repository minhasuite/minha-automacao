module HelperTypes
  # Integral (integration do HA, soma de Riemann): potência (W) → energia
  # (kWh). Métodos trapezoidal (padrão), esquerda e direita; prefixo de
  # unidade (k, M, G) e unidade de tempo; casas decimais. Origem fora do ar =
  # o tempo sem leitura não entra (recomeça na volta). "Intervalo máximo sem
  # leitura": se a origem fica parada mais que isso, integra assim mesmo com o
  # valor atual (o relógio, `tick`), como o `max_sub_interval` do HA.
  class Integral < Plugin
    METHODS = { "trapezoidal" => "Trapezoidal (padrão)", "left" => "Esquerda (valor de antes)", "right" => "Direita (valor novo)" }.freeze

    describe key: "integral", title: "Integral", icon: "chart-square-bar", capability: "measure",
             description: "Acumula um valor no tempo: potência (W) vira energia (kWh), vazão vira volume."
    fields %i[source method prefix time_unit round max_interval]

    def self.assign(point, form)
      src = numeric_source!(point, form) or return
      a = point.address
      prefix = (form.key?("prefix") ? form["prefix"].to_s : a["prefix"].to_s).presence_in(PREFIXES.keys) || ""
      unit = (form["time_unit"] || a["time_unit"]).presence_in(TIME_UNITS.keys) || "h"
      round = (number(form["round"]) || a["round"] || 3).to_i
      max = form.key?("max_interval") ? Automations::Dsl.seconds(form["max_interval"].to_s.strip.presence || 0) : a["max_s"].to_i
      point.data_type = "decimal"
      point.writable = false
      point.unit = "#{prefix}#{src.unit}#{unit}"
      point.address = a.merge("method" => (form["method"] || a["method"]).presence_in(METHODS.keys) || "trapezoidal", "prefix" => prefix,
                              "time_unit" => unit, "round" => round, "max_s" => max.to_i.positive? ? max.to_i : nil).compact
      point.errors.add(:base, "Casas decimais de 0 a 6.") unless round.between?(0, 6)
      point.errors.add(:base, "Intervalo máximo inválido (ex.: 5m, 1h).") if max.nil? || (max.to_i.positive? && max.to_i < 60)
    end

    def self.sourced? = true
    def self.clocked? = true

    def self.refresh!(point, now = Time.current)
      v = reading(source(point))
      s = state(point)
      area = 0.0
      if v && s["last"] && s["at"]
        dt = now - Time.zone.parse(s["at"])
        a = point.address
        y = { "left" => s["last"], "right" => v }.fetch(a["method"]) { (s["last"] + v) / 2.0 }
        area = y * dt.clamp(0, nil) / PREFIXES[a["prefix"].to_s] / TIME_UNITS[a["time_unit"]]
      end
      total = s["total"].to_f + area
      # Fora do ar: guarda o total e esquece o último ponto (o buraco não entra).
      save_state!(point, { "total" => total, "last" => v, "at" => (now.iso8601(3) if v) }.compact)
      value = total.round(point.address["round"].to_i)
      point.report!(value) if value != point.value
    end

    # Origem parada mais que o intervalo máximo: integra com o valor atual.
    def self.tick(point, now)
      max = point.address["max_s"].to_i
      at = state(point)["at"]
      refresh!(point, now) if max.positive? && at && now - Time.zone.parse(at) >= max
    end

    def self.summary(point)
      a = point.address
      [ METHODS[a["method"]]&.split(" (")&.first, "em #{point.unit}", ("a cada #{Automations::Dsl.duration_label(a['max_s'])} sem leitura" if a["max_s"]) ].compact.join(" · ")
    end
  end
end
