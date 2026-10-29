# Rollups de hora e dia (ESQUEMA-V1 §4.4). Recalcula as últimas horas (pega
# leitura atrasada e a hora corrente, parcial) e os dias que elas tocam, com
# upsert: rodar de novo não duplica. Booleano ganha `on_seconds` mesmo em hora
# sem leitura (o estado vem da última leitura anterior).
# ponytail: média simples das leituras (não ponderada pelo tempo) e dia no
# fuso da app, não no do local; refinar quando houver local fora de SP.
class RollupReadingsJob < ApplicationJob
  queue_as :default

  HOURS_BACK = 3

  def perform(now = Time.current)
    from = now.beginning_of_hour - HOURS_BACK.hours
    hourly(from, now)
    on_seconds(from, now)
    daily(from.beginning_of_day, now)
  end

  private

  def run(sql, *binds) = ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql_array([ sql.squish, *binds ]))

  def hourly(from, to)
    run(<<~SQL, from, to)
      INSERT INTO reading_rollups (point_id, bucket, starts_at, min, max, avg, sum, last, count)
      SELECT point_id, '1h', date_trunc('hour', at), min(value), max(value), avg(value), sum(value),
             (array_agg(value ORDER BY at DESC))[1], count(*)
      FROM readings WHERE at >= ? AND at < ? AND value IS NOT NULL
      GROUP BY point_id, date_trunc('hour', at)
      ON CONFLICT (point_id, bucket, starts_at) DO UPDATE SET min = EXCLUDED.min, max = EXCLUDED.max,
        avg = EXCLUDED.avg, sum = EXCLUDED.sum, last = EXCLUDED.last, count = EXCLUDED.count
    SQL
  end

  # Segundos ligado por hora de cada ponto booleano com histórico.
  def on_seconds(from, to)
    ids = ActsAsTenant.without_tenant { Point.where(data_type: "bool").where.not(history: "none").pluck(:id) }
    return if ids.empty?

    before = Reading.where(point_id: ids, at: ...from).select("DISTINCT ON (point_id) point_id, value")
                    .order(:point_id, at: :desc).to_h { |r| [ r.point_id, r.value ] }
    inside = Reading.where(point_id: ids, at: from...to).order(:at).group_by(&:point_id)
    rows = ids.flat_map { |id| hours_on(id, before[id], inside.fetch(id, []), from, to) }
    rows.each_slice(1000) { |s| ReadingRollup.upsert_all(s, unique_by: %i[point_id bucket starts_at], update_only: %i[on_seconds]) }
  end

  def hours_on(id, state, readings, from, to)
    return [] if state.nil? && readings.empty?

    hour = from
    rows = []
    while hour < to
      stop = [ hour + 1.hour, to ].min
      seconds = 0
      cursor = hour
      readings.each do |r|
        next if r.at < hour
        break if r.at >= stop

        seconds += r.at - cursor if state.to_i == 1
        state = r.value
        cursor = r.at
      end
      seconds += stop - cursor if state.to_i == 1
      rows << { point_id: id, bucket: "1h", starts_at: hour, on_seconds: seconds.round } unless state.nil?
      hour += 1.hour
    end
    rows
  end

  def daily(from, to)
    zone = Time.zone.tzinfo.name
    run(<<~SQL, from, to)
      INSERT INTO reading_rollups (point_id, bucket, starts_at, min, max, avg, sum, last, count, on_seconds)
      SELECT point_id, '1d', (date_trunc('day', starts_at AT TIME ZONE 'UTC' AT TIME ZONE '#{zone}') AT TIME ZONE '#{zone}') AT TIME ZONE 'UTC',
             min(min), max(max), sum(sum) / NULLIF(sum(count), 0), sum(sum),
             (array_agg(last ORDER BY starts_at DESC) FILTER (WHERE last IS NOT NULL))[1], sum(count), sum(on_seconds)
      FROM reading_rollups WHERE bucket = '1h' AND starts_at >= ? AND starts_at < ?
      GROUP BY 1, 3
      ON CONFLICT (point_id, bucket, starts_at) DO UPDATE SET min = EXCLUDED.min, max = EXCLUDED.max,
        avg = EXCLUDED.avg, sum = EXCLUDED.sum, last = EXCLUDED.last, count = EXCLUDED.count, on_seconds = EXCLUDED.on_seconds
    SQL
  end
end
