# Gráfico do histórico em SVG gerado no servidor (sem lib de JS): linha para
# número (com a faixa mín–máx nos rollups) e faixas ligado/desligado para
# booleano. Eixo X de 0 a 1000 e Y de 0 a 100, esticados pelo CSS; os rótulos
# ficam em HTML para não deformar.
module ChartsHelper
  W = 1000.0
  H = 100.0

  # { svg:, min:, max:, on_seconds: } ou nil (sem dado ou tipo sem gráfico).
  def history_chart(history)
    history.point.bool? ? bands_chart(history) : line_chart(history)
  end

  # Widget de gráfico (dashboard): um booleano vira faixas; números viram
  # linhas na mesma escala, uma cor por série (.dw-s0…). { svg:, min:, max:,
  # on_seconds:, series: [[ponto, índice]], from:, to: } ou nil sem dado.
  def dashboard_chart(points, range)
    from = (Time.current - Points::History::RANGES.fetch(range, 24.hours)).iso8601
    histories = points.map { |p| Points::History.new(p, from: from) }
    return if histories.empty?
    return history_chart(histories.first)&.merge(series: [ [ points.first, 0 ] ], from: histories.first.from, to: histories.first.to) if points.first.bool?

    series = histories.each_with_index.filter_map do |h, i|
      rows = h.raw? ? h.items.map { |r| [ r.at, r.value ] } : h.items.map { |r| [ r.starts_at, r.avg ] }
      rows = rows.reject { |_, v| v.nil? }
      [ h, rows, i ] if rows.any? && !h.point.bool?
    end
    return if series.empty?

    values = series.flat_map { |_, rows, _| rows.map { |r| r[1].to_f } }
    lo, hi = [ values.min, 0 ].min, values.max
    hi = lo + 1 if hi == lo
    y = ->(v) { (H - 4 - ((v.to_f - lo) / (hi - lo) * (H - 8))).round(2) }
    shapes = series.map do |h, rows, i|
      line = rows.map { |at, v| "#{chart_x(h, at)},#{y.(v)}" }
      line << "#{chart_x(h, [ Time.current, h.to ].min)},#{y.(rows.last[1])}" if h.raw?
      tag.polyline(points: line.join(" "), fill: "none", class: "dw-s#{i % 6}", "stroke-width": 2,
                   "vector-effect": "non-scaling-stroke", "stroke-linejoin": "round")
    end
    { svg: svg_tag(safe_join(shapes)), min: lo, max: hi, series: series.map { |h, _, i| [ h.point, i ] }, from: histories.first.from, to: histories.first.to }
  end

  private

  def chart_x(history, at) = ((at - history.from) / (history.to - history.from) * W).clamp(0, W).round(1)

  def bands_chart(history)
    rects = []
    on_since = nil
    history.items.each do |r|
      on = r.value.to_i == 1
      on_since ||= r.at if on
      next if on || on_since.nil?

      rects << [ on_since, r.at ]
      on_since = nil
    end
    rects << [ on_since, [ Time.current, history.to ].min ] if on_since
    return if history.items.empty?

    shapes = rects.map do |a, b|
      x = chart_x(history, a)
      tag.rect(x: x, y: 0, width: [ chart_x(history, b) - x, 1 ].max, height: H, rx: 1, class: "fill-accent", "fill-opacity": 0.75)
    end
    { svg: svg_tag(safe_join(shapes)), on_seconds: rects.sum { |a, b| b - a }.round }
  end

  def line_chart(history)
    rows = history.raw? ? history.items.map { |r| [ r.at, r.value, r.value, r.value ] } : history.items.map { |r| [ r.starts_at, r.avg, r.min, r.max ] }
    rows = rows.reject { |_, v| v.nil? }
    return if rows.empty?

    lo = rows.map { |r| r[2] }.min.to_f
    hi = rows.map { |r| r[3] }.max.to_f
    lo, hi = lo - 1, hi + 1 if lo == hi
    y = ->(v) { (H - 6 - ((v.to_f - lo) / (hi - lo) * (H - 12))).round(2) }
    line = rows.map { |at, v| "#{chart_x(history, at)},#{y.(v)}" }
    line << "#{chart_x(history, [ Time.current, history.to ].min)},#{y.(rows.last[1])}" if history.raw?
    shapes = []
    unless history.raw?
      band = rows.map { |at, _, _, mx| "#{chart_x(history, at)},#{y.(mx)}" } + rows.reverse.map { |at, _, mn, _| "#{chart_x(history, at)},#{y.(mn)}" }
      shapes << tag.polygon(points: band.join(" "), class: "fill-accent", "fill-opacity": 0.12)
    end
    shapes << tag.polyline(points: line.join(" "), fill: "none", class: "stroke-accent", "stroke-width": 2,
                           "vector-effect": "non-scaling-stroke", "stroke-linejoin": "round")
    { svg: svg_tag(safe_join(shapes)), min: lo, max: hi }
  end

  def svg_tag(content)
    tag.svg(content, viewBox: "0 0 #{W.to_i} #{H.to_i}", preserveAspectRatio: "none", class: "block w-full h-40 sm:h-48",
                     "aria-hidden": true)
  end
end
