module Points
  # Histórico de vários pontos na mesma janela (tela Histórico, API e CSV),
  # como o History do HA: número vira linha (um gráfico por unidade, as
  # linhas sobrepostas) e o resto vira faixas na linha do tempo (um trecho
  # por valor). Lê pelo `Points::History` (cru, por hora ou por dia).
  class Overlay
    MAX = 12
    RANGES = { "1h" => 1.hour, "6h" => 6.hours, "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.freeze
    RANGE_LABELS = { "1h" => "1 h", "6h" => "6 h", "24h" => "24 h", "7d" => "7 dias", "30d" => "30 dias" }.freeze
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
      to = now if to.nil? || to > now
      from = to - RANGES.fetch(params[:range].to_s, 24.hours) if from.nil? || from >= to
      from = to - MAX_SPAN if to - from > MAX_SPAN
      from = to - MIN_SPAN if to - from < MIN_SPAN
      [ from, to ]
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
