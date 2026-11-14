module Points
  # Histórico de vários pontos na mesma janela (tela Histórico, API e CSV),
  # como o History do HA: número vira linha (um gráfico por unidade, as
  # linhas sobrepostas) e o resto vira faixas na linha do tempo (um trecho
  # por valor). Lê pelo `Points::History` (cru, por hora ou por dia).
  class Overlay
    MAX = 12
    RANGES = { "1h" => 1.hour, "6h" => 6.hours, "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.freeze
    RANGE_LABELS = LocalizedLabel.for("labels.periods", %w[1h 6h 24h 7d 30d])
    # Dias do calendário no fuso do local (a janela é calculada dentro do Time.use_zone).
    DAYS = %w[today yesterday].freeze
    DAY_LABELS = LocalizedLabel.for("history.days", DAYS)
    # Sugestões de comparação (tela Histórico): grupos com pelo menos MIN_GROUP pontos.
    SUGGESTIONS = 6
    MIN_GROUP = 2
    # O que vira faixa e vale sugerir junto (portas, movimento, presença).
    BAND_GROUPS = %w[contact motion occupancy presence].freeze
    MIN_SPAN = 5.minutes
    MAX_SPAN = 366.days

    # rows: linha → [[at, média, mín, máx]]; faixas → [[de, até, valor, texto]].
    Series = Struct.new(:point, :kind, :resolution, :rows, keyword_init: true) do
      def line? = kind == "line"
    end

    attr_reader :points, :from, :to

    # Janela pelos parâmetros: `range` (até agora) ou `from`/`to`; inválido = 24 h.
    def self.window(params, now: Time.current)
      to = parse(params[:to])
      from = parse(params[:from])
      day = day_window(params[:range].to_s, now) and return day
      to = now if to.nil? || to > now
      from = to - RANGES.fetch(params[:range].to_s, 24.hours) if from.nil? || from >= to
      from = to - MAX_SPAN if to - from > MAX_SPAN
      from = to - MIN_SPAN if to - from < MIN_SPAN
      [ from, to ]
    end

    # Hoje (do começo do dia até agora) ou ontem (o dia inteiro), no fuso atual.
    def self.day_window(range, now)
      case range
      when "today" then [ now.beginning_of_day, now ]
      when "yesterday" then [ (now - 1.day).beginning_of_day, now.beginning_of_day ]
      end
    end

    # A janela [de, até] bate com o atalho `key`? (o chip marcado)
    def self.current?(key, from, to, now: Time.current)
      want = day_window(key.to_s, now) || (RANGES[key.to_s] && [ now - RANGES[key.to_s], now ])
      want.present? && (want[0] - from).abs < 1.minute && (want[1] - to).abs < 1.minute
    end

    # Grupos prontos para comparar (o "temperaturas da casa"): medidas da mesma
    # unidade e mesma classe (ou nome) e, para faixas, a mesma capacidade.
    # → [{label:, ids:, unit:, count:}], os maiores primeiro.
    def self.suggestions(site)
      pts = site.points.where(hidden: false, disabled: false, helper: nil, device_id: site.devices.listed.select(:id)).includes(:device).to_a
      groups = pts.group_by do |p|
        if p.numeric? && p.capability == "measure" then [ "n", p.unit.to_s, p.device_class.presence || p.name.to_s.downcase ]
        elsif BAND_GROUPS.include?(p.capability) then [ "b", p.capability ]
        end
      end
      groups.delete(nil)
      groups.select { |_, list| list.size >= MIN_GROUP }.sort_by { |k, list| [ -list.size, k.join ] }.first(SUGGESTIONS).map do |key, list|
        name = list.map(&:name).tally.max_by { |n, c| [ c, -n.size ] }.first
        { label: name, unit: (key[1].presence if key[0] == "n"), count: list.size, ids: list.sort_by { |p| [ p.device&.name.to_s, p.name ] }.first(MAX).map(&:id) }
      end
    end

    def self.parse(v) = v.presence && (Time.zone.parse(v.to_s) rescue nil) # rubocop:disable Style/RescueModifier

    def initialize(points, from:, to:)
      @points = points.first(MAX)
      @from = from
      @to = to
    end

    def series = @series ||= points.filter_map { |p| p.numeric? ? line(p) : bands(p) }
    def lines = series.select(&:line?)
    def timelines = series.reject(&:line?)
    # Gráficos de linha por unidade ({unidade → séries}).
    def charts = lines.group_by { |s| s.point.unit.to_s }

    def as_json(*)
      series.map do |s|
        { point_id: s.point.id, name: s.point.name, key: s.point.key, unit: s.point.unit, kind: s.kind, resolution: s.resolution,
          items: s.rows.map { |r| s.line? ? { at: r[0], avg: r[1]&.to_f, min: r[2]&.to_f, max: r[3]&.to_f } : { from: r[0], to: r[1], value: r[2], text: r[3] } } }
      end.as_json
    end

    # CSV: uma linha por leitura (ou por hora/dia, com mín e máx) de cada ponto.
    def to_csv(zone)
      require "csv"
      CSV.generate(col_sep: ";") do |csv|
        csv << %w[ponto chave unidade inicio fim valor minimo maximo]
        series.each do |s|
          s.rows.each do |r|
            t = ->(x) { x.in_time_zone(zone).iso8601 }
            csv << if s.line?
                     [ s.point.name, s.point.key, s.point.unit, t.(r[0]), nil, num(r[1]), num(r[2]), num(r[3]) ]
            else
                     [ s.point.name, s.point.key, s.point.unit, t.(r[0]), t.(r[1]), r[3], nil, nil ]
            end
          end
        end
      end
    end

    private

    def num(v) = v&.to_f&.round(4)&.to_s&.tr(".", ",")

    def line(p)
      h = History.new(p, from: from.iso8601, to: to.iso8601)
      rows = h.raw? ? h.items.map { |r| [ r.at, r.value, r.value, r.value ] } : h.items.map { |r| [ r.starts_at, r.avg, r.min, r.max ] }
      Series.new(point: p, kind: "line", resolution: h.resolution, rows: rows.reject { |r| r[1].nil? })
    end

    def bands(p)
      items = History.new(p, from: from.iso8601, to: to.iso8601, resolution: "raw").items
      stop = [ to, Time.current ].min
      rows = items.each_with_index.filter_map do |r, i|
        ends = items[i + 1]&.at || stop
        next if ends <= r.at

        v = Logbook.value_of(p, r)
        [ r.at, ends, v, Logbook.text(p, v) ]
      end
      Series.new(point: p, kind: "bands", resolution: "raw", rows: rows)
    end
  end
end
