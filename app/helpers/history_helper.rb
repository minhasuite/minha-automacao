# Tela Histórico: gráfico de linhas sobrepostas (SVG no servidor, como o
# ChartsHelper) e a linha do tempo de faixas. A cor de cada série é a mesma
# na legenda, no gráfico e no cursor (var(--s0…s5)).
module HistoryHelper
  W = 1000.0
  H = 100.0

  def hx_color(i) = "var(--s#{i % 6})"
  def hx_x(at, from, to) = ((at - from) / (to - from) * W).clamp(0, W).round(1)

  # → {svg:, min:, max:} das séries (todas com a mesma unidade).
  def hx_line_chart(series, from, to, index)
    values = series.flat_map { |s| s.rows.flat_map { |r| [ r[2], r[3] ] } }.compact.map(&:to_f)
    return if values.empty?

    lo, hi = values.minmax
    pad = (hi - lo).zero? ? 1 : (hi - lo) * 0.08
    lo -= pad
    hi += pad
    y = ->(v) { (H - ((v.to_f - lo) / (hi - lo) * H)).round(2) }
    shapes = series.flat_map do |s|
      color = hx_color(index[s.point.id])
      line = s.rows.map { |r| "#{hx_x(r[0], from, to)},#{y.(r[1])}" }
      line << "#{hx_x([ to, Time.current ].min, from, to)},#{y.(s.rows.last[1])}" if s.resolution == "raw" && s.rows.any?
      band = unless s.resolution == "raw"
               up = s.rows.map { |r| "#{hx_x(r[0], from, to)},#{y.(r[3])}" }
               down = s.rows.reverse.map { |r| "#{hx_x(r[0], from, to)},#{y.(r[2])}" }
               tag.polygon(points: (up + down).join(" "), style: "fill: #{color}; fill-opacity: .1")
      end
      [ band, tag.polyline(points: line.join(" "), fill: "none", style: "stroke: #{color}", "stroke-width": 2,
                                                   "vector-effect": "non-scaling-stroke", "stroke-linejoin": "round") ]
    end
    grid = [ 25, 50, 75 ].map { |g| tag.line(x1: 0, x2: W, y1: g, y2: g, class: "hx-grid", "vector-effect": "non-scaling-stroke") }
    svg = tag.svg(safe_join(grid + shapes.compact), viewBox: "0 0 #{W.to_i} #{H.to_i}", preserveAspectRatio: "none", class: "hx-svg", "aria-hidden": true)
    { svg: svg, min: lo, max: hi }
  end

  # Faixas de um ponto (ligado em destaque; outros valores por cor da opção).
  def hx_bands(s, from, to)
    options = s.point.option_values
    rects = s.rows.map do |a, b, v, text|
      x = hx_x(a, from, to)
      tone = if v == true || v.to_s.in?(%w[on open]) then "hx-on"
      elsif v == false || v.nil? || v.to_s.in?(%w[off closed]) then "hx-off"
      else "hx-o#{(options.index(v.to_s) || v.to_s.sum) % 6}"
      end
      tag.rect(tag.title("#{text} · #{l(a, format: '%d/%m %H:%M')} a #{l(b, format: '%d/%m %H:%M')}"),
               x: x, y: 0, width: [ hx_x(b, from, to) - x, 0.6 ].max, height: 10, class: tone)
    end
    tag.svg(safe_join(rects), viewBox: "0 0 #{W.to_i} 10", preserveAspectRatio: "none", class: "hx-band-svg", role: "img",
                              "aria-label": "#{s.point.name}: #{s.rows.map { |r| r[3] }.uniq.first(4).join(', ')}")
  end

  # Rótulos do eixo do tempo (5 marcas).
  def hx_ticks(from, to, zone)
    fmt = to - from <= 36.hours ? "%H:%M" : "%d/%m"
    (0..4).map { |i| (from + ((to - from) * i / 4)).in_time_zone(zone).strftime(fmt) }
  end

  # Dados do cursor do gráfico (Stimulus history-chart): epoch em ms e média.
  def hx_cursor_data(series, index)
    series.map do |s|
      { name: s.point.name, unit: s.point.unit.to_s, color: index[s.point.id] % 6,
        pts: s.rows.map { |r| [ (r[0].to_f * 1000).round, r[1]&.to_f&.round(3) ] } }
    end.to_json
  end

  # Mesma tela com outra janela (zoom e deslocamento), mantendo os pontos.
  def hx_path(site, ids, from, to) = history_path(site_id: site.id, point_ids: ids, from: from.iso8601, to: to.iso8601)
end
