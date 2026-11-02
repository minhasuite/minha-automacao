module Health
  # Verificações que vêm com o produto. Nenhuma é da casa: leem integrações,
  # aparelhos, fila, backup, disco e sombra de qualquer instalação.
  module Checks
    # Contas de serviço (Alexa, Tuya, Xiaomi...): status, último ok e erro.
    class Integrations < Check
      describe key: "integrations", label: "Integrações", icon: "link"
      texts "pt-BR" => { empty: "Nenhuma integração" },
            en: { label: "Integrations", empty: "No integrations" },
            es: { label: "Integraciones", empty: "Ninguna integración" }

      def self.items(tenant)
        list = Integration.includes(:site).order(:name).to_a
        return [ item(key: "none", status: "ok", title: text(:empty)) ] if list.empty?

        list.map do |i|
          status = { "error" => "error", "pending" => "warn" }.fetch(i.status, "ok")
          item(key: i.id, status: status, title: "#{i.name} (#{i.site.name})", at: i.last_ok_at,
               detail: [ i.status_label, (text(:last_ok, at: I18n.l(i.last_ok_at, format: :short)) if i.last_ok_at), i.last_error ].compact.join(" · "))
        end
      end
    end

    # Aparelhos sem sinal ou parados e pontos sem leitura, por local.
    class Devices < Check
      describe key: "devices", label: "Aparelhos e pontos", icon: "chip"
      texts "pt-BR" => { offline: "%{site}: aparelhos sem sinal", all_ok: "Todos respondendo", stale: "%{site}: aparelhos sem atualizar",
                         fresh: "Leituras em dia", points: "%{site}: pontos sem sinal", unavailable: "%{n} ponto(s) indisponível(is)", more: " e mais %{n}" },
            en: { label: "Devices and points", offline: "%{site}: devices offline", all_ok: "All responding", stale: "%{site}: devices not updating",
                  fresh: "Readings up to date", points: "%{site}: points offline", unavailable: "%{n} point(s) unavailable", more: " and %{n} more" },
            es: { label: "Dispositivos y puntos", offline: "%{site}: dispositivos sin señal", all_ok: "Todos responden", stale: "%{site}: dispositivos sin actualizar",
                  fresh: "Lecturas al día", points: "%{site}: puntos sin señal", unavailable: "%{n} punto(s) no disponible(s)", more: " y %{n} más" }
      OFFLINE_ALERT = 1.hour

      def self.items(_tenant)
        Site.order(:name).flat_map do |site|
          devices = site.devices.listed.where(disabled: false, removed_at: nil)
          offline = devices.where(status: %w[offline error]).order(:name).to_a
          stale = devices.where("poll_s > 0 AND last_seen_at < now() - make_interval(secs => poll_s * 3)").order(:name).to_a
          points = site.points.where(quality: "unavailable", disabled: false, hidden: false).count
          long = offline.any? { |d| d.last_seen_at.nil? || d.last_seen_at < OFFLINE_ALERT.ago }
          [ item(key: "#{site.id}:offline", status: offline.empty? ? "ok" : (long ? "error" : "warn"), title: text(:offline, site: site.name),
                 detail: offline.empty? ? text(:all_ok) : "#{offline.size}: #{names(offline)}"),
            item(key: "#{site.id}:stale", status: stale.empty? ? "ok" : "warn", title: text(:stale, site: site.name),
                 detail: stale.empty? ? text(:fresh) : "#{stale.size}: #{names(stale)}"),
            item(key: "#{site.id}:points", status: points.zero? ? "ok" : "warn", title: text(:points, site: site.name),
                 detail: points.zero? ? text(:none) : text(:unavailable, n: points)) ]
        end
      end

      def self.names(list) = list.first(5).map(&:name).join(", ") + (list.size > 5 ? text(:more, n: list.size - 5) : "")
    end

    # Fila do Solid Queue (do servidor, não da instalação): trabalhador vivo, atraso e falhas.
    class Queues < Check
      describe key: "queues", label: "Fila de tarefas", icon: "clock"
      texts "pt-BR" => { queue: "Fila", other: "Fora do Solid Queue neste ambiente (%{adapter})", worker: "Trabalhador", running: "Rodando",
                         dead: "Sem sinal há mais de 5 min", delay: "Atraso", oldest: "Tarefa mais antiga esperando: %{s} s · agendadas atrasadas: %{late}",
                         failed_24: "Falhas em 24 h", failures: "%{n} tarefa(s) falharam (%{kept} guardadas)" },
            en: { label: "Job queue", queue: "Queue", other: "Not on Solid Queue in this environment (%{adapter})", worker: "Worker", running: "Running",
                  dead: "No heartbeat for over 5 min", delay: "Delay", oldest: "Oldest job waiting: %{s} s · scheduled jobs running late: %{late}",
                  failed_24: "Failures in 24 h", failures: "%{n} job(s) failed (%{kept} kept)" },
            es: { label: "Cola de tareas", queue: "Cola", other: "Fuera de Solid Queue en este entorno (%{adapter})", worker: "Trabajador", running: "En ejecución",
                  dead: "Sin señal hace más de 5 min", delay: "Retraso", oldest: "Tarea más antigua esperando: %{s} s · programadas atrasadas: %{late}",
                  failed_24: "Fallas en 24 h", failures: "%{n} tarea(s) fallaron (%{kept} guardadas)" }
      DELAY_WARN = 2.minutes
      DELAY_ERROR = 10.minutes
      HEARTBEAT = 5.minutes

      def self.items(_tenant)
        return [ item(key: "adapter", status: "ok", title: text(:queue), detail: text(:other, adapter: adapter)) ] unless adapter == "solid_queue"

        oldest = SolidQueue::ReadyExecution.minimum(:created_at)
        late = SolidQueue::ScheduledExecution.where(scheduled_at: ...DELAY_WARN.ago).count
        delay = oldest ? Time.current - oldest : 0
        failed = SolidQueue::FailedExecution.where(created_at: 24.hours.ago..).count
        alive = SolidQueue::Process.where(kind: "Worker", last_heartbeat_at: HEARTBEAT.ago..).exists?
        [ item(key: "worker", status: alive ? "ok" : "error", title: text(:worker), detail: alive ? text(:running) : text(:dead)),
          item(key: "delay", status: delay > DELAY_ERROR ? "error" : (delay > DELAY_WARN || late.positive? ? "warn" : "ok"), title: text(:delay),
               detail: text(:oldest, s: delay.round, late: late)),
          item(key: "failed", status: failed.positive? ? "error" : "ok", title: text(:failed_24),
               detail: failed.positive? ? text(:failures, n: failed, kept: SolidQueue::FailedExecution.count) : text(:none)) ]
      end

      def self.adapter = ActiveJob::Base.queue_adapter_name.to_s
    end

    # Último dump local, cópia externa e teste de restauração (G20).
    class Backup < Check
      describe key: "backup", label: "Backup", icon: "download"
      texts "pt-BR" => { daily: "Cópia diária no servidor", last: "Última: %{at}", no_dir: "Sem pasta de backup neste servidor", offsite: "Cópia fora de casa",
                         not_set: "Não configurada (docs/backup.md)", last_at: "última %{at}", restore: "Teste de restauração", no_offsite: "Sem cópia externa",
                         restore_wait: "Ainda não rodou (domingo, 5h)" },
            en: { label: "Backup", daily: "Daily copy on the server", last: "Latest: %{at}", no_dir: "No backup folder on this server", offsite: "Off-site copy",
                  not_set: "Not set up (docs/backup.md)", last_at: "latest %{at}", restore: "Restore test", no_offsite: "No off-site copy",
                  restore_wait: "Hasn't run yet (Sunday, 5 AM)" },
            es: { label: "Respaldo", daily: "Copia diaria en el servidor", last: "Última: %{at}", no_dir: "No hay carpeta de respaldo en este servidor",
                  offsite: "Copia fuera de casa", not_set: "No configurada (docs/backup.md)", last_at: "última %{at}", restore: "Prueba de restauración",
                  no_offsite: "Sin copia externa", restore_wait: "Todavía no se ejecutó (domingo, 5 h)" }

      def self.items(_tenant)
        local = ::Integrations::SystemPlugin.last_backup
        s = ::Backups.status
        [ item(key: "local", status: local.nil? ? "warn" : (local < ::Integrations::SystemPlugin::BACKUP_LATE.ago ? "error" : "ok"), at: local,
               title: text(:daily), detail: local ? text(:last, at: I18n.l(local, format: :short)) : text(:no_dir)),
          offsite(s), restore(s) ]
      end

      def self.offsite(s)
        return item(key: "offsite", status: "warn", title: text(:offsite), detail: text(:not_set)) unless ::Backups.configured?

        at = ::Backups.time("uploaded_at")
        detail = [ s["destination"], (text(:last_at, at: I18n.l(at, format: :short)) if at), (text(:failed, error: s["error"]) if s["error"]) ].compact.join(" · ")
        item(key: "offsite", status: ::Backups.offsite_ok? ? "ok" : "error", title: text(:offsite), at: at, detail: detail.presence || text(:not_run))
      end

      def self.restore(s)
        return item(key: "restore", status: "warn", title: text(:restore), detail: text(:no_offsite)) unless ::Backups.configured?

        at = ::Backups.time("restored_at")
        status = if ::Backups.restore_ok? then "ok"
        elsif s["restore_error"] then "error"
        else "warn"
        end
        detail = [ (text(:last_ok, at: I18n.l(at, format: :short)) if at), (text(:failed, error: s["restore_error"]) if s["restore_error"]) ].compact.join(" · ")
        item(key: "restore", status: status, title: text(:restore), at: at, detail: detail.presence || text(:restore_wait))
      end
    end

    class Disk < Check
      describe key: "disk", label: "Disco", icon: "archive"
      texts "pt-BR" => { unreadable: "Não deu para ler", usage: "%{used}% usado · %{free} GB livres" },
            en: { label: "Disk", unreadable: "Couldn't read it", usage: "%{used}% used · %{free} GB free" },
            es: { label: "Disco", unreadable: "No se pudo leer", usage: "%{used}% usado · %{free} GB libres" }

      def self.items(_tenant)
        d = ::Integrations::SystemPlugin.disk
        return [ item(key: "disk", status: "warn", title: label, detail: text(:unreadable)) ] unless d

        status = d[:used] >= 90 ? "error" : (d[:used] >= 80 ? "warn" : "ok")
        [ item(key: "disk", status: status, title: label, detail: text(:usage, used: d[:used], free: d[:free])) ]
      end
    end

    # Versão e tempo no ar (deste processo).
    class Runtime < Check
      describe key: "runtime", label: "Versão e tempo no ar", icon: "information-circle"
      texts "pt-BR" => { dev: "desenvolvimento", version: "Versão", up_since: "No ar desde" },
            en: { label: "Version and uptime", dev: "development", version: "Version", up_since: "Up since" },
            es: { label: "Versión y tiempo activo", dev: "desarrollo", version: "Versión", up_since: "Activo desde" }

      def self.items(_tenant)
        version = ENV["APP_VERSION"].presence&.first(12) || text(:dev)
        [ item(key: "version", status: "ok", title: text(:version), detail: "#{version} · Ruby #{RUBY_VERSION} · Rails #{Rails.version}"),
          item(key: "uptime", status: "ok", title: text(:up_since), at: BOOTED_AT,
               detail: "#{I18n.l(BOOTED_AT, format: :short)} (#{uptime(Time.current - BOOTED_AT)})") ]
      end

      def self.uptime(seconds)
        d, rest = seconds.to_i.divmod(86_400)
        h, rest = rest.divmod(3600)
        [ ("#{d} d" if d.positive?), ("#{h} h" if d.positive? || h.positive?), "#{rest / 60} min" ].compact.join(" ")
      end
    end

    # Sombra (F10): resultado da última comparação de cada local.
    class Shadow < Check
      describe key: "shadow", label: "Sombra", icon: "moon"
      texts "pt-BR" => { waiting: "Em sombra, sem comparação ainda", on: "Em sombra", off: "Fora da sombra", last: "%{state} · última comparação %{at}: ",
                         clean: "sem divergência", diverge: "%{n} divergência(s)", none_site: "Nenhum local em sombra" },
            en: { label: "Shadow", waiting: "In shadow, no comparison yet", on: "In shadow", off: "Out of shadow", last: "%{state} · last comparison %{at}: ",
                  clean: "no differences", diverge: "%{n} difference(s)", none_site: "No place in shadow" },
            es: { label: "Sombra", waiting: "En sombra, todavía sin comparación", on: "En sombra", off: "Fuera de la sombra", last: "%{state} · última comparación %{at}: ",
                  clean: "sin diferencias", diverge: "%{n} diferencia(s)", none_site: "Ningún lugar en sombra" }
      DIVERGENT = %w[different missing extra].freeze

      def self.items(_tenant)
        Site.order(:name).filter_map do |site|
          report = ShadowReport.where(site_id: site.id).recent.first
          on = ::Shadow.site?(site)
          next unless report || on

          next item(key: site.id, status: "warn", title: site.name, detail: text(:waiting)) unless report

          div = divergences(report)
          item(key: site.id, status: div.zero? ? "ok" : "warn", title: site.name, at: report.created_at,
               detail: text(:last, state: text(on ? :on : :off), at: I18n.l(report.created_at, format: :short)) +
                       (div.zero? ? text(:clean) : text(:diverge, n: div)))
        end.presence || [ item(key: "none", status: "ok", title: label, detail: text(:none_site)) ]
      end

      def self.divergences(report) = DIVERGENT.sum { |k| report.summary[k].to_i }
    end

    # O que falta para trocar o Home Assistant (ou outro sistema) por este (docs/cutover.md). Só informa.
    class Cutover < Check
      describe key: "cutover", label: "Pronto para a troca", icon: "check-circle", alerts: false
      texts en: { label: "Ready to switch" }, es: { label: "Listo para el cambio" }

      def self.items(tenant) = ::Cutover.items(tenant)
    end
  end
end
