# Desempenho (Configurações → Saúde → "Desempenho"): tempo médio e pior por
# tela (controller#ação, pelo `process_action.action_controller`) e por
# widget do painel (`Perf.measure` no Resolver). Amostragem leve: cada
# processo soma na memória (contagem, soma, pior) e no máximo uma vez por
# FLUSH junta a soma no balde da hora no Rails.cache (24 baldes). Nada vai
# para tabela; duas gravações ao mesmo tempo podem perder uma soma (é amostra).
module Perf
  FLUSH = 60.seconds
  HOURS = 24
  KINDS = %w[screen widget].freeze
  # Telas que não contam (saúde do contêiner, cable, arquivos).
  SKIP = %w[Rails::HealthController ActionCable ActiveStorage].freeze
  # Uma tela que ninguém vai olhar não enche o balde: no máximo tantas chaves por tipo.
  MAX_KEYS = 300

  @buffer = {}
  @lock = Mutex.new
  @flushed_at = Time.current

  module_function

  def measure(kind, key)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    record(kind, key, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000.0) if t
  end

  def record(kind, key, ms)
    return if key.blank?

    due = @lock.synchronize do
      stat = (@buffer["#{kind}|#{key}"] ||= [ 0, 0.0, 0.0 ])
      stat[0] += 1
      stat[1] += ms
      stat[2] = ms if ms > stat[2]
      Time.current - @flushed_at >= FLUSH
    end
    flush! if due
  end

  # Junta o que este processo somou no balde da hora (Rails.cache).
  def flush!(now = Time.current)
    batch = @lock.synchronize do
      @flushed_at = now
      @buffer.tap { @buffer = {} }
    end
    return if batch.empty?

    key = bucket_key(now)
    data = Rails.cache.read(key) || {}
    batch.each do |k, (n, sum, max)|
      next if !data.key?(k) && data.size >= MAX_KEYS * KINDS.size

      c, s, m = data[k] || [ 0, 0.0, 0.0 ]
      data[k] = [ c + n, s + sum, [ m, max ].max ]
    end
    Rails.cache.write(key, data, expires_in: (HOURS + 1).hours)
  rescue StandardError => e
    Rails.logger.warn("[perf] #{e.class}: #{e.message}")
  end

  def bucket_key(time) = "perf:#{time.utc.strftime('%Y%m%d%H')}"

  # [{kind, key, count, avg, max}] das últimas `hours` horas, já com o que este processo ainda não juntou.
  def stats(hours: HOURS, now: Time.current)
    keys = Array.new(hours) { |i| bucket_key(now - i.hours) }
    merged = {}
    (Rails.cache.read_multi(*keys).values + [ @lock.synchronize { @buffer.transform_values(&:dup) } ]).each do |data|
      data.each do |k, (n, sum, max)|
        c, s, m = merged[k] || [ 0, 0.0, 0.0 ]
        merged[k] = [ c + n, s + sum, [ m, max ].max ]
      end
    end
    merged.map do |k, (n, sum, max)|
      kind, key = k.split("|", 2)
      { kind: kind, key: key, count: n, avg: n.zero? ? 0 : (sum / n).round(1), max: max.round(1) }
    end
  end

  def reset!
    @lock.synchronize do
      @buffer = {}
      @flushed_at = Time.current
    end
  end

  # Liga a medição das telas (config/initializers/perf.rb).
  def subscribe!
    ActiveSupport::Notifications.subscribe("process_action.action_controller") do |event|
      p = event.payload
      next if SKIP.any? { |s| p[:controller].to_s.start_with?(s) }

      record("screen", "#{p[:controller]}##{p[:action]}", event.duration)
    end
  end
end
