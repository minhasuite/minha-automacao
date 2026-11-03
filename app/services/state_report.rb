# Avisar ecossistemas de fora quando um ponto muda (ondaC1, C6): cada
# relator diz se o ponto interessa (`wants?`) e é chamado numa tarefa
# (StateReportJob), sem segurar o `Point#report!`. Relator novo = classe com
# `wants?(point)` e `report!(site, points)` + nome em REPORTERS.
module StateReport
  REPORTERS = %w[GoogleHome::Reporter Integrations::InfluxdbPlugin].freeze

  module_function

  def reporters = REPORTERS.map(&:constantize)

  def changed(point)
    keys = reporters.select { |r| r.wants?(point) }.map(&:name)
    StateReportJob.perform_later(point.id, keys) if keys.any?
  end
end
