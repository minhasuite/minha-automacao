module HelperTypes
  # Estatística do histórico (history_stats do HA, ondaA1 A10): quanto
  # tempo (horas), que fração (%) ou quantas vezes um ponto ficou num valor
  # num período (hoje, últimas 24 h, últimos 7 dias, este mês), lido do
  # histórico (`readings`). Refaz quando a origem muda e a cada minuto.
  class HistoryStats < Plugin
    KINDS = { "time" => "h", "ratio" => "%", "count" => nil }.freeze
    PERIODS = %w[today last_24h last_7d month].freeze

    describe key: "history_stats", title: "Estatística do histórico", icon: "chart-square-bar", capability: "measure",
             description: "Quanto tempo, que fração ou quantas vezes um ponto ficou num valor: horas de bomba ligada hoje, vezes que a porta abriu."
    fields %i[source state kind period]
    texts "pt-BR" => { "form.source" => "Ponto", "form.state" => "No valor (on, off, número ou texto)", "form.kind" => "Medir", "form.period" => "Período",
                       "kind.time" => "Tempo (horas)", "kind.ratio" => "Fração do período (%)", "kind.count" => "Vezes que entrou no valor",
                       "period.today" => "Hoje", "period.last_24h" => "Últimas 24 h", "period.last_7d" => "Últimos 7 dias", "period.month" => "Este mês",
                       pick: "Escolha o ponto e o valor.", summary: "%{kind} em %{state}, %{period}" },
          en: { title: "History stats", description: "How long, what share or how many times a point was in a value: pump hours today, times the door opened.",
                "form.source" => "Point", "form.state" => "In the value (on, off, number or text)", "form.kind" => "Measure", "form.period" => "Period",
                "kind.time" => "Time (hours)", "kind.ratio" => "Share of the period (%)", "kind.count" => "Times it entered the value",
                "period.today" => "Today", "period.last_24h" => "Last 24 h", "period.last_7d" => "Last 7 days", "period.month" => "This month",
                pick: "Choose the point and the value.", summary: "%{kind} in %{state}, %{period}" },
          es: { title: "Estadística del historial", description: "Cuánto tiempo, qué fracción o cuántas veces un punto estuvo en un valor: horas de bomba encendida hoy, veces que se abrió la puerta.",
                "form.source" => "Punto", "form.state" => "En el valor (on, off, número o texto)", "form.kind" => "Medir", "form.period" => "Período",
                "kind.time" => "Tiempo (horas)", "kind.ratio" => "Fracción del período (%)", "kind.count" => "Veces que entró en el valor",
                "period.today" => "Hoy", "period.last_24h" => "Últimas 24 h", "period.last_7d" => "Últimos 7 días", "period.month" => "Este mes",
                pick: "Elige el punto y el valor.", summary: "%{kind} en %{state}, %{period}" }

    def self.form_spec
      [ [ :source, :point, { index: 0 } ], [ :state, :text, { placeholder: "on" } ],
        [ :kind, :select, { choices: -> { KINDS.keys.index_with { |k| text("kind.#{k}") } } } ],
        [ :period, :select, { choices: -> { PERIODS.index_with { |k| text("period.#{k}") } } } ] ]
    end

    def self.assign(point, form)
      a = point.address
      src = point.site.points.find_by(id: form["source"].presence || a.dig("sources", 0))
      state = form.fetch("state", a["state_value"]).to_s.strip
      return point.errors.add(:base, text(:pick)) if src.nil? || src.id == point.id || state.empty?

      kind = form.fetch("kind", a["kind"]).to_s.presence_in(KINDS.keys) || "time"
      period = form.fetch("period", a["period"]).to_s.presence_in(PERIODS) || "today"
      point.data_type = kind == "count" ? "integer" : "decimal"
      point.writable = false
      point.unit = KINDS[kind]
      point.address = a.merge("sources" => [ src.id ], "state_value" => state, "kind" => kind, "period" => period)
    end

    def self.sourced? = true
    def self.clocked? = true
    def self.tick(point, now) = refresh!(point, now)

    def self.window(point, now)
      local = now.in_time_zone(ActiveSupport::TimeZone[point.site.timezone])
      start = { "today" => local.beginning_of_day, "last_24h" => now - 24.hours, "last_7d" => now - 7.days, "month" => local.beginning_of_month }.fetch(point.address["period"])
      [ start, now ]
    end

    def self.hit?(reading, want)
      return reading.value.to_i == (want == "on" ? 1 : 0) if %w[on off].include?(want) && reading.value
      return reading.value.to_f == want.tr(",", ".").to_f if reading.value && want.match?(/\A-?[\d.,]+\z/)

      reading.value_text.to_s == want
    end

    def self.refresh!(point, now = Time.current)
      src = source(point) or return point.report!(point.value, quality: "unavailable")
      start, stop = window(point, now)
      want = point.address["state_value"].to_s
      before = Reading.where(point_id: src.id).where(at: ...start).order(at: :desc).first
      list = Reading.where(point_id: src.id, at: start..stop).order(:at).to_a
      list.unshift(Reading.new(point_id: src.id, at: start, value: before.value, value_text: before.value_text)) if before
      secs = 0.0
      count = 0
      list.each_with_index do |r, i|
        on = hit?(r, want)
        count += 1 if on && (i.zero? ? r.at > start : !hit?(list[i - 1], want))
        secs += ((list[i + 1]&.at || stop) - r.at) if on
      end
      value = case point.address["kind"]
      when "count" then count
      when "ratio" then (100.0 * secs / (stop - start)).round(1)
      else (secs / 3600.0).round(2)
      end
      point.report!(value) unless value == point.value
    end

    def self.summary(point)
      a = point.address
      text(:summary, kind: text("kind.#{a['kind']}").downcase, state: a["state_value"], period: text("period.#{a['period']}").downcase)
    end
  end
end
