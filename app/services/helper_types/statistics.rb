module HelperTypes
  # Estatística (statistics do HA): média, mínimo, máximo ou soma de um ponto
  # numérico numa janela de tempo, pelas leituras do histórico.
  # ponytail: só se refaz quando o ponto de origem muda; numa janela parada o
  # valor velho não "sai" sozinho. Se precisar, refazer também pelo relógio.
  class Statistics < Plugin
    FUNCS = { "mean" => "Média", "median" => "Mediana", "min" => "Mínimo", "max" => "Máximo", "sum" => "Soma" }.freeze
    MAX_WINDOW = 30.days.to_i

    describe key: "statistics", title: "Estatística", icon: "chart-bar", capability: "measure",
             description: "Média, mínimo, máximo ou soma de um sensor numa janela: temperatura média da última hora."
    fields %i[source func window]
    texts "pt-BR" => { funcs: FUNCS, window: "Janela inválida (use 30m, 1h, 24h; até 30 dias).", summary: "%{func} em %{time}" },
          en: { title: "Statistics", description: "Average, minimum, maximum or sum of a sensor over a window: average temperature over the last hour.",
                funcs: { mean: "Average", median: "Median", min: "Minimum", max: "Maximum", sum: "Sum" },
                window: "Invalid window (use 30m, 1h, 24h; up to 30 days).", summary: "%{func} over %{time}" },
          es: { title: "Estadística", description: "Promedio, mínimo, máximo o suma de un sensor en una ventana: temperatura promedio de la última hora.",
                funcs: { mean: "Promedio", median: "Mediana", min: "Mínimo", max: "Máximo", sum: "Suma" },
                window: "Ventana no válida (usa 30m, 1h, 24h; hasta 30 días).", summary: "%{func} en %{time}" }

    def self.funcs = labels(:funcs, FUNCS)

    def self.assign(point, form)
      source = point.site.points.find_by(id: form["source"].presence || point.address.dig("sources", 0))
      return point.errors.add(:base, text(:pick_source)) unless source&.numeric? && source.id != point.id

      window = Automations::Dsl.seconds(form["window"].presence || point.address["window_s"] || "")
      return point.errors.add(:base, text(:window)) unless window&.between?(60, MAX_WINDOW)

      point.data_type = "decimal"
      point.writable = false
      point.unit = source.unit
      point.address = point.address.merge("sources" => [ source.id ], "func" => form["func"].presence_in(FUNCS.keys) || "mean", "window_s" => window)
    end

    def self.sourced? = true

    def self.refresh!(point)
      source = point.site.points.find_by(id: point.address.dig("sources", 0)) or return
      nums = Reading.where(point_id: source.id, at: (Time.current - point.address["window_s"].to_i)..).where.not(value: nil).pluck(:value).map(&:to_f)
      # A leitura do valor atual já está no histórico; sem histórico, vale o valor atual.
      nums << source.value.to_f if nums.empty? && source.value.is_a?(Numeric)
      point.report!(Group.aggregate(point.address["func"], nums))
    end

    def self.summary(point) = text(:summary, func: funcs[point.address["func"]].to_s, time: Automations::Dsl.duration_label(point.address["window_s"].to_i))
  end
end
