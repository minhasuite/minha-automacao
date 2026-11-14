# Tela Histórico: os dados do Ss::TimeSeriesChartComponent (um gráfico por
# unidade) e do Ss::StateBandsComponent (a linha do tempo). A cor de cada
# série é a mesma na pílula, na legenda e no gráfico (var(--series-1…6)).
module HistoryHelper
  def hx_color(i) = "var(--series-#{i % 6 + 1})"

  # Séries de uma unidade para o gráfico: cru = [t, valor] (a última leitura
  # vale até agora); por hora/dia = [t, média, mín, máx] (faixa atrás da linha).
  def hx_series(series, index, to)
    series.map do |s|
      raw = s.resolution == "raw"
      pts = s.rows.map { |r| raw ? [ r[0], r[1] ] : r }
      pts << [ [ to, Time.current ].min, s.rows.last[1] ] if raw && s.rows.any?
      { name: Logbook.point_title(s.point), unit: s.point.unit.presence, color: hx_color(index[s.point.id]), points: pts }
    end
  end

  # Linhas da linha do tempo: um trecho por valor (ligado na marca, desligado
  # no neutro, as opções na paleta de séries).
  def hx_band_rows(timelines)
    timelines.map do |s|
      { label: Logbook.point_title(s.point), current: point_value_text(s.point),
        segments: s.rows.map { |a, b, v, text| { from: a, to: b, state: v.nil? ? "unknown" : v.to_s, label: text.to_s } } }
    end
  end

  # Resumo da série na janela (legenda do gráfico): mínimo, máximo e média
  # (média das médias por hora/dia, ou das leituras cruas). nil sem leituras.
  def hx_stats(series)
    rows = series.rows.reject { |r| r[1].nil? }
    return if rows.empty?

    mins = rows.map { |r| (r[2] || r[1]).to_f }
    maxs = rows.map { |r| (r[3] || r[1]).to_f }
    { min: mins.min, max: maxs.max, avg: rows.sum { |r| r[1].to_f } / rows.size }
  end

  # Número com a unidade do ponto, no formato da tela (vírgula decimal, até 1 casa acima de 10).
  def hx_num(value, unit)
    v = value.to_f
    txt = number_with_precision(v, precision: v.abs >= 10 ? 1 : 2, strip_insignificant_zeros: true)
    unit.present? ? "#{txt} #{unit}" : txt
  end

  # Mesma tela com outra janela (zoom e deslocamento), mantendo os pontos.
  def hx_path(site, ids, from, to) = history_path(site_id: site.id, point_ids: ids, from: from.iso8601, to: to.iso8601)
end
