# Histórico de pontos (Points::History) no formato do Ss::TimeSeriesChartComponent
# da gem: número vira série (com mínimo e máximo nos rollups), liga/desliga vira
# faixa de estado. O desenho (eixos, cursor, legenda) é do componente.
module ChartsHelper
  # Um ponto → { series: } ou { band:, on_seconds: }; nil sem leitura.
  def chart_data(history, name: history.point.name)
    history.point.bool? ? chart_band(history, name) : chart_line(history, name)
  end

  # Vários pontos no mesmo período (widget de gráfico): { series:, bands:, on_seconds:, from:, to: } ou nil.
  def dashboard_chart(points, range)
    from = (Time.current - Points::History::RANGES.fetch(range, 24.hours)).iso8601
    histories = points.map { |p| Points::History.new(p, from: from) }
    return if histories.empty?

    parts = histories.filter_map { |h| chart_data(h, name: h.point.device&.name.presence || h.point.name) }
    return if parts.empty?

    { series: parts.filter_map { |c| c[:series] }, bands: parts.filter_map { |c| c[:band] },
      on_seconds: parts.sum { |c| c[:on_seconds].to_i }.nonzero?, from: histories.first.from, to: histories.first.to }
  end

  private

  def chart_line(history, name)
    rows = history.raw? ? history.items.map { |r| [ r.at, r.value ] } : history.items.map { |r| [ r.starts_at, r.avg, r.min, r.max ] }
    rows = rows.reject { |r| r[1].nil? }
    return if rows.empty?

    p = history.point
    { series: { name: name, unit: p.unit.to_s, decimals: (p.step.to_f % 1).zero? && p.step ? 0 : 1, points: rows } }
  end

  def chart_band(history, name)
    return if history.items.empty?

    spans = []
    on_since = nil
    history.items.each do |r|
      on = r.value.to_i == 1
      on_since ||= r.at if on
      next if on || on_since.nil?

      spans << [ on_since, r.at ]
      on_since = nil
    end
    spans << [ on_since, [ Time.current, history.to ].min ] if on_since
    on_label = point_value_label(history.point, true)
    { band: { label: name, segments: spans.map { |a, b| { from: a, to: b, state: "on", label: on_label } } }, on_seconds: spans.sum { |a, b| b - a }.round }
  end
end
