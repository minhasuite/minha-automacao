# Fila e jobs (Configurações → Fila; docs/fila.md): retrato do Solid Queue e da
# latência dos comandos. Tudo por índice e com LIMIT: o servidor de casa roda
# num HDD e a tela se recarrega a cada 10 s.
#
# Latência do comando (a pergunta "o atraso é a fila ou o aparelho?"):
#   fila     = sent_at − created_at (pedido → o job começou a executar)
#   aparelho = confirmed_at − sent_at (o driver mandou e o aparelho respondeu)
#
# Job: o Solid Queue não guarda quando o job começou, só quando ficou pronto
# (scheduled_at) e quando terminou (finished_at). Por isso a estatística por
# classe é "espera + execução"; a espera separada só existe para quem está
# rodando agora (claimed_executions.created_at) e, nos comandos, acima.
module QueueMonitor
  LIST_LIMIT = 50
  FAILED_COMMANDS_LIMIT = 20
  BACKTRACE_LINES = 5
  WINDOWS = { "1h" => 1.hour, "24h" => 24.hours }.freeze
  TABS = %w[execucao agendados erros concluidos].freeze

  QUEUE_S = "EXTRACT(EPOCH FROM (commands.sent_at - commands.created_at))".freeze
  DEVICE_S = "EXTRACT(EPOCH FROM (commands.confirmed_at - commands.sent_at))".freeze
  JOB_S = "EXTRACT(EPOCH FROM (solid_queue_jobs.finished_at - COALESCE(solid_queue_jobs.scheduled_at, solid_queue_jobs.created_at)))".freeze

  module_function

  # O Solid Queue é do servidor inteiro: mesma regra dos Logs (dono, uma instalação só).
  def visible_to?(user) = SystemLog.visible_to?(user)

  def summary(now = Time.current)
    alive_since = now - SolidQueue.process_alive_threshold
    oldest = SolidQueue::ReadyExecution.minimum(:created_at)
    {
      ready: SolidQueue::ReadyExecution.count,
      claimed: SolidQueue::ClaimedExecution.count,
      scheduled: SolidQueue::ScheduledExecution.count,
      blocked: SolidQueue::BlockedExecution.count,
      failed: SolidQueue::FailedExecution.count,
      finished_24h: SolidQueue::Job.where(finished_at: (now - 24.hours)..).count,
      oldest_ready_s: oldest && (now - oldest).round(1),
      processes_alive: SolidQueue::Process.where(last_heartbeat_at: alive_since..).count,
      processes: SolidQueue::Process.count
    }
  end

  def processes(now = Time.current)
    alive_since = now - SolidQueue.process_alive_threshold
    SolidQueue::Process.order(:kind, :name).limit(LIST_LIMIT).map do |p|
      { kind: p.kind, name: p.name, pid: p.pid, hostname: p.hostname, last_heartbeat_at: p.last_heartbeat_at, alive: p.last_heartbeat_at >= alive_since }
    end
  end

  def recurring
    tasks = SolidQueue::RecurringTask.order(:key).limit(LIST_LIMIT).to_a
    last = SolidQueue::RecurringExecution.where(task_key: tasks.map(&:key)).group(:task_key).maximum(:run_at)
    tasks.map do |t|
      { key: t.key, schedule: t.schedule, job: t.class_name.presence || t.command.to_s.truncate(60), last_run_at: last[t.key], next_run_at: next_time(t) }
    end
  end

  def next_time(task)
    task.next_time
  rescue StandardError
    nil
  end

  # { "1h" => { total: {...}, drivers: [{driver:, ...}] }, "24h" => ... } com segundos.
  def command_latency(now = Time.current)
    WINDOWS.transform_values { |span| latency_since(now - span) }
  end

  def latency_since(since)
    cols = [ "devices.driver", "count(*)",
             "count(*) FILTER (WHERE commands.status = 'failed')", "count(*) FILTER (WHERE commands.status = 'expired')",
             *percentiles(QUEUE_S), *percentiles(DEVICE_S) ]
    rows = Command.joins(point: :device).where(created_at: since..)
                  .group(Arel.sql("GROUPING SETS ((devices.driver), ())"))
                  .pluck(*cols.map { Arel.sql(_1) })
    stats = rows.map do |driver, n, failed, expired, qp50, qp95, qmax, dp50, dp95, dmax|
      { driver: driver, count: n, failed: failed, expired: expired,
        queue: { p50: secs(qp50), p95: secs(qp95), max: secs(qmax) },
        device: { p50: secs(dp50), p95: secs(dp95), max: secs(dmax) } }
    end
    total = stats.find { _1[:driver].nil? } || empty_latency
    { total: total.except(:driver), drivers: stats.select { _1[:driver] }.sort_by { [ -_1[:count], _1[:driver] ] } }
  end

  def percentiles(expr)
    [ "percentile_cont(0.5) WITHIN GROUP (ORDER BY #{expr})", "percentile_cont(0.95) WITHIN GROUP (ORDER BY #{expr})", "max(#{expr})" ]
  end

  def empty_latency
    blank = { p50: nil, p95: nil, max: nil }
    { driver: nil, count: 0, failed: 0, expired: 0, queue: blank, device: blank }
  end

  def secs(value) = value&.to_f&.round(3)

  def recent_commands(limit: LIST_LIMIT)
    Command.includes(point: :device).order(created_at: :desc).limit(limit).map { command_row(_1) }
  end

  def failed_commands(now = Time.current, limit: FAILED_COMMANDS_LIMIT)
    Command.includes(point: :device).where(created_at: (now - 24.hours).., status: %w[failed expired])
           .order(created_at: :desc).limit(limit).map { command_row(_1) }
  end

  def command_row(c)
    { id: c.id, point: c.point&.name, driver: c.point&.device&.driver, command: c.command, value: c.value,
      status: c.status, source: c.source, error: c.error, created_at: c.created_at,
      queue_s: c.sent_at && secs(c.sent_at - c.created_at),
      device_s: c.sent_at && c.confirmed_at && secs(c.confirmed_at - c.sent_at) }
  end

  # Por classe, nas últimas 24 h: concluídos, falhas e espera + execução (média, p95, máximo).
  def job_stats(now = Time.current)
    since = now - 24.hours
    done = SolidQueue::Job.where(finished_at: since..).group(:class_name)
                          .pluck(:class_name, Arel.sql("count(*)"), Arel.sql("avg(#{JOB_S})"),
                                 Arel.sql("percentile_cont(0.95) WITHIN GROUP (ORDER BY #{JOB_S})"), Arel.sql("max(#{JOB_S})"))
    failed = SolidQueue::FailedExecution.joins(:job).where(created_at: since..).group("solid_queue_jobs.class_name").count
    rows = done.to_h { |klass, n, avg, p95, max| [ klass, { job: klass, count: n, failed: 0, avg_s: secs(avg), p95_s: secs(p95), max_s: secs(max) } ] }
    failed.each { |klass, n| (rows[klass] ||= { job: klass, count: 0, failed: 0, avg_s: nil, p95_s: nil, max_s: nil })[:failed] = n }
    rows.values.sort_by { [ -_1[:count], _1[:job] ] }
  end

  def list(tab, now = Time.current)
    case tab
    when "agendados" then scheduled
    when "erros" then failed
    when "concluidos" then finished(now)
    else running(now)
    end
  end

  def running(now = Time.current)
    SolidQueue::ClaimedExecution.includes(:job, :process).order(:id).limit(LIST_LIMIT).map do |e|
      ready_at = e.job.scheduled_at || e.job.created_at
      { id: e.id, job: e.job.class_name, args: args_summary(e.job), queue: e.job.queue_name, since: e.created_at,
        running_s: secs(now - e.created_at), waited_s: secs(e.created_at - ready_at),
        process: e.process && "#{e.process.name} (#{e.process.pid})" }
    end
  end

  def scheduled
    SolidQueue::ScheduledExecution.includes(:job).order(:scheduled_at, :priority, :job_id).limit(LIST_LIMIT).map do |e|
      { id: e.id, job: e.job.class_name, args: args_summary(e.job), queue: e.queue_name, at: e.scheduled_at }
    end
  end

  def failed
    SolidQueue::FailedExecution.includes(:job).order(id: :desc).limit(LIST_LIMIT).map do |e|
      err = e.error.is_a?(Hash) ? e.error.with_indifferent_access : {}
      { id: e.id, job: e.job.class_name, args: args_summary(e.job), queue: e.job.queue_name, at: e.created_at,
        error_class: err[:exception_class], message: err[:message].to_s.truncate(500),
        backtrace: Array(err[:backtrace]).first(BACKTRACE_LINES) }
    end
  end

  def finished(now = Time.current)
    SolidQueue::Job.where(finished_at: (now - 24.hours)..).order(finished_at: :desc).limit(LIST_LIMIT).map do |j|
      { id: j.id, job: j.class_name, args: args_summary(j), queue: j.queue_name, at: j.finished_at,
        total_s: secs(j.finished_at - (j.scheduled_at || j.created_at)) }
    end
  end

  def count(tab)
    case tab
    when "agendados" then SolidQueue::ScheduledExecution.count
    when "erros" then SolidQueue::FailedExecution.count
    when "concluidos" then SolidQueue::Job.where(finished_at: 24.hours.ago..).count
    else SolidQueue::ClaimedExecution.count
    end
  end

  # Argumentos do ActiveJob em uma linha: registro por GlobalID vira "Modelo abc12345".
  def args_summary(job)
    data = job.arguments
    args = data.is_a?(Hash) ? Array(data["arguments"]) : Array(data)
    args.map { arg_text(_1) }.join(", ").truncate(120)
  rescue StandardError
    ""
  end

  def arg_text(arg)
    case arg
    when Hash
      gid = arg["_aj_globalid"]
      return gid.to_s.sub(%r{\Agid://[^/]+/}, "").sub(%r{/(\h{8})[\h-]*\z}, ' \1') if gid

      arg.except("_aj_symbol_keys", "_aj_ruby2_keywords").to_json
    else arg.to_s
    end
  end

  def retry!(id) = SolidQueue::FailedExecution.find(id).retry
  def discard!(id) = SolidQueue::FailedExecution.find(id).discard

  # Resumo para a API (/api/v1/system/queue) e para o app no futuro.
  def snapshot(now = Time.current)
    { summary: summary(now), command_latency: command_latency(now), processes: processes(now),
      recurring: recurring, jobs: job_stats(now) }
  end
end
