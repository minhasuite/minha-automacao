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

  # Mesma tela com outra janela (zoom e deslocamento), mantendo os pontos.
  def hx_path(site, ids, from, to) = history_path(site_id: site.id, point_ids: ids, from: from.iso8601, to: to.iso8601)
end
