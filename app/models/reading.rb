# Leitura de histórico de um ponto (ESQUEMA-V1 §4.4). Tabela particionada por
# mês (`readings_AAAA_MM`, em UTC) e sem tenant: chega-se nela pelo ponto.
# Número e booleano (1/0) vão em `value`; texto e JSON em `value_text`.
class Reading < ApplicationRecord
  self.primary_key = nil

  belongs_to :point

  # Cru guardado por padrão (o ponto com `retention_days` menor apaga antes).
  RETENTION_DAYS = 365

  # Grava a leitura do valor atual do ponto, respeitando `history`
  # (`none` não grava; `interval` grava no máximo uma a cada
  # history_interval_s) e a banda morta (só grava se mudar mais que isso: a
  # do ponto ou a padrão da medida, Points::Deadband).
  def self.record!(point, at)
    return if point.history == "none"

    num, text = split(point.value)
    band = Points::Deadband.for(point)
    band = nil if band&.zero?
    if band || point.history == "interval"
      last = where(point_id: point.id).order(at: :desc).first
      return if point.history == "interval" && last && last.at > at - point.history_interval_s.to_i.seconds
      return if band && last&.value && num && (num - last.value).abs < band
    end
    insert_all!([ { point_id: point.id, at: at, value: num, value_text: text } ], returning: false)
  end

  def self.split(value)
    case value
    when true, false then [ value ? 1 : 0, nil ]
    when Numeric then [ value, nil ]
    when nil then [ nil, nil ]
    when String then [ nil, value ]
    else [ nil, value.to_json ]
    end
  end

  def self.partition_name(month) = "readings_#{month.strftime('%Y_%m')}"

  # Partições do mês atual e do próximo (idempotente; meses em UTC).
  def self.ensure_partitions!(now = Time.current)
    month = now.utc.beginning_of_month
    [ month, month.next_month ].each do |m|
      connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{connection.quote_table_name(partition_name(m))} PARTITION OF readings
        FOR VALUES FROM (#{connection.quote(m.to_fs(:db))}) TO (#{connection.quote(m.next_month.to_fs(:db))})
      SQL
    end
  end

  # Apaga as partições cujo mês inteiro passou da retenção (a maior entre o
  # padrão e a de algum ponto). Devolve os nomes apagados.
  def self.drop_old_partitions!(now = Time.current)
    days = [ RETENTION_DAYS, ActsAsTenant.without_tenant { Point.maximum(:retention_days) }.to_i ].max
    cutoff = (now - days.days).utc
    names = connection.select_values(<<~SQL)
      SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
      JOIN pg_class p ON p.oid = i.inhparent WHERE p.relname = 'readings'
    SQL
    names.grep(/\Areadings_\d{4}_\d{2}\z/).select { |n| Time.utc(*n.delete_prefix("readings_").split("_").map(&:to_i)).next_month <= cutoff }
         .each { |n| connection.execute("DROP TABLE #{connection.quote_table_name(n)}") }
  end
end
