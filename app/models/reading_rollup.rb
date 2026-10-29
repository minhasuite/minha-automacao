# Resumo de leituras por hora (`1h`) e dia (`1d`, dia de America/Sao_Paulo):
# min/max/média/soma/último e, no booleano, segundos ligado. Gráficos longos
# leem daqui (ESQUEMA-V1 §4.4). Calculado pelo RollupReadingsJob.
class ReadingRollup < ApplicationRecord
  self.primary_key = nil

  BUCKETS = %w[1h 1d].freeze

  belongs_to :point
end
