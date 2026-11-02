module HelperTypes
  # Filtro (filter do HA, ondaA1 A10): suaviza um sensor ruidoso. Média
  # móvel das últimas N leituras, passa-baixa (cada leitura pesa 1/N) ou
  # descarte de pico (leitura que se afasta mais que o raio da mediana das
  # últimas N fica de fora). O estado (amostras) fica em `address.state`.
  class Filter < Plugin
    KINDS = %w[moving_average lowpass outlier].freeze
    MAX_WINDOW = 100

    describe key: "filter", title: "Filtro", icon: "filter", capability: "measure",
             description: "Suaviza um sensor que oscila: média das últimas leituras, passa-baixa ou descarte de picos."
    fields %i[source kind window radius decimals]
    texts "pt-BR" => { "form.source" => "Sensor de origem", "form.kind" => "Filtro", "form.window" => "Leituras (N)", "form.radius" => "Raio do pico (descarte)",
                       "form.decimals" => "Casas decimais", "kind.moving_average" => "Média móvel", "kind.lowpass" => "Passa-baixa", "kind.outlier" => "Descartar picos",
                       window: "Leituras de 1 a %{max}.", radius: "Informe o raio do descarte (maior que zero).", summary: "%{kind}, %{n} leituras" },
          en: { title: "Filter", description: "Smooths a jumpy sensor: average of the last readings, low-pass or outlier removal.",
                "form.source" => "Source sensor", "form.kind" => "Filter", "form.window" => "Readings (N)", "form.radius" => "Outlier radius",
                "form.decimals" => "Decimal places", "kind.moving_average" => "Moving average", "kind.lowpass" => "Low-pass", "kind.outlier" => "Remove outliers",
                window: "Readings from 1 to %{max}.", radius: "Enter the outlier radius (greater than zero).", summary: "%{kind}, %{n} readings" },
          es: { title: "Filtro", description: "Suaviza un sensor que oscila: promedio de las últimas lecturas, pasa bajos o descarte de picos.",
                "form.source" => "Sensor de origen", "form.kind" => "Filtro", "form.window" => "Lecturas (N)", "form.radius" => "Radio del pico",
                "form.decimals" => "Decimales", "kind.moving_average" => "Media móvil", "kind.lowpass" => "Pasa bajos", "kind.outlier" => "Descartar picos",
                window: "Lecturas de 1 a %{max}.", radius: "Indica el radio del descarte (mayor que cero).", summary: "%{kind}, %{n} lecturas" }

    def self.form_spec
      [ [ :source, :source, { index: 0 } ], [ :kind, :select, { choices: -> { KINDS.index_with { |k| text("kind.#{k}") } } } ],
        [ :window, :number, { value: ->(p) { p.address["window"] || 5 } } ], [ :radius, :number ], [ :decimals, :number, { value: ->(p) { p.address["decimals"] || 2 } } ] ]
    end

    def self.assign(point, form)
      src = numeric_source!(point, form) or return
      a = point.address
      kind = form.fetch("kind", a["kind"]).to_s.presence_in(KINDS) || "moving_average"
      window = (form.key?("window") ? number(form["window"]) : a["window"] || 5).to_i
      radius = form.key?("radius") ? number(form["radius"]) : a["radius"]
      decimals = (form.key?("decimals") ? number(form["decimals"]) : a["decimals"] || 2).to_i
      point.data_type = "decimal"
      point.writable = false
      point.unit = src.unit
      point.address = a.merge("kind" => kind, "window" => window, "radius" => radius, "decimals" => decimals)
      return point.errors.add(:base, text(:window, max: MAX_WINDOW)) unless window.between?(1, MAX_WINDOW)
      return point.errors.add(:base, text(:decimals)) unless decimals.between?(0, 6)

      point.errors.add(:base, text(:radius)) if kind == "outlier" && !radius.to_f.positive?
    end

    def self.sourced? = true

    def self.refresh!(point)
      v = reading(source(point))
      return point.report!(point.value, quality: "unavailable") if v.nil?

      a = point.address
      samples = (state(point)["samples"] || []).last(a["window"].to_i - 1) + [ v ]
      out = case a["kind"]
      when "lowpass" then lowpass(point.value, v, a["window"].to_i)
      when "outlier" then outlier(samples[0..-2].presence || [ v ], v, a["radius"].to_f)
      else samples.sum / samples.size
      end
      save_state!(point, "samples" => samples)
      point.report!(out.round(a["decimals"].to_i))
    end

    def self.lowpass(prev, v, n) = prev.is_a?(Numeric) ? prev + ((v - prev) / n.to_f) : v

    # Fica a leitura se está dentro do raio da mediana; senão, a mediana.
    def self.outlier(samples, v, radius)
      sorted = samples.sort
      median = sorted.size.odd? ? sorted[sorted.size / 2] : (sorted[(sorted.size / 2) - 1] + sorted[sorted.size / 2]) / 2.0
      (v - median).abs > radius ? median : v
    end

    def self.summary(point) = text(:summary, kind: text("kind.#{point.address['kind']}"), n: point.address["window"])
  end
end
