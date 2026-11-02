module Health
  # Verificações que vêm com o produto. Nenhuma é da casa: leem integrações,
  # aparelhos, fila, backup, disco e sombra de qualquer instalação.
  module Checks
    # Contas de serviço (Alexa, Tuya, Xiaomi...): status, último ok e erro.
    class Integrations < Check
      describe key: "integrations", label: "Integrações", icon: "link"

      def self.items(tenant)
        list = Integration.includes(:site).order(:name).to_a
        return [ item(key: "none", status: "ok", title: "Nenhuma integração") ] if list.empty?

        list.map do |i|
          status = { "error" => "error", "pending" => "warn" }.fetch(i.status, "ok")
          item(key: i.id, status: status, title: "#{i.name} (#{i.site.name})", at: i.last_ok_at,
               detail: [ i.status_label, ("último ok #{I18n.l(i.last_ok_at, format: :short)}" if i.last_ok_at), i.last_error ].compact.join(" · "))
        end
      end
    end

    # Aparelhos sem sinal ou parados e pontos sem leitura, por local.
    class Devices < Check
      describe key: "devices", label: "Aparelhos e pontos", icon: "chip"
      OFFLINE_ALERT = 1.hour

      def self.items(_tenant)
        Site.order(:name).flat_map do |site|
          devices = site.devices.listed.where(disabled: false, removed_at: nil)
          offline = devices.where(status: %w[offline error]).order(:name).to_a
          stale = devices.where("poll_s > 0 AND last_seen_at < now() - make_interval(secs => poll_s * 3)").order(:name).to_a
          points = site.points.where(quality: "unavailable", disabled: false, hidden: false).count
          long = offline.any? { |d| d.last_seen_at.nil? || d.last_seen_at < OFFLINE_ALERT.ago }
          [ item(key: "#{site.id}:offline", status: offline.empty? ? "ok" : (long ? "error" : "warn"), title: "#{site.name}: aparelhos sem sinal",
                 detail: offline.empty? ? "Todos respondendo" : "#{offline.size}: #{names(offline)}"),
            item(key: "#{site.id}:stale", status: stale.empty? ? "ok" : "warn", title: "#{site.name}: aparelhos sem atualizar",
                 detail: stale.empty? ? "Leituras em dia" : "#{stale.size}: #{names(stale)}"),
            item(key: "#{site.id}:points", status: points.zero? ? "ok" : "warn", title: "#{site.name}: pontos sem sinal",
                 detail: points.zero? ? "Nenhum" : "#{points} ponto(s) indisponível(is)") ]
        end
      end

      def self.names(list) = list.first(5).map(&:name).join(", ") + (list.size > 5 ? " e mais #{list.size - 5}" : "")
    end

    # Fila do Solid Queue (do servidor, não da instalação): trabalhador vivo, atraso e falhas.
    class Queues < Check
      describe key: "queues", label: "Fila de tarefas", icon: "clock"
      DELAY_WARN = 2.minutes
      DELAY_ERROR = 10.minutes
      HEARTBEAT = 5.minutes

      def self.items(_tenant)
        return [ item(key: "adapter", status: "ok", title: "Fila", detail: "Fora do Solid Queue neste ambiente (#{adapter})") ] unless adapter == "solid_queue"

        oldest = SolidQueue::ReadyExecution.minimum(:created_at)
        late = SolidQueue::ScheduledExecution.where(scheduled_at: ...DELAY_WARN.ago).count
        delay = oldest ? Time.current - oldest : 0
        failed = SolidQueue::FailedExecution.where(created_at: 24.hours.ago..).count
        alive = SolidQueue::Process.where(kind: "Worker", last_heartbeat_at: HEARTBEAT.ago..).exists?
        [ item(key: "worker", status: alive ? "ok" : "error", title: "Trabalhador", detail: alive ? "Rodando" : "Sem sinal há mais de 5 min"),
          item(key: "delay", status: delay > DELAY_ERROR ? "error" : (delay > DELAY_WARN || late.positive? ? "warn" : "ok"), title: "Atraso",
               detail: "Tarefa mais antiga esperando: #{delay.round} s · agendadas atrasadas: #{late}"),
          item(key: "failed", status: failed.positive? ? "error" : "ok", title: "Falhas em 24 h",
               detail: failed.positive? ? "#{failed} tarefa(s) falharam (#{SolidQueue::FailedExecution.count} guardadas)" : "Nenhuma") ]
      end

      def self.adapter = ActiveJob::Base.queue_adapter_name.to_s
    end

    # Último dump local, cópia externa e teste de restauração (G20).
    class Backup < Check
      describe key: "backup", label: "Backup", icon: "download"

      def self.items(_tenant)
        local = ::Integrations::SystemPlugin.last_backup
        s = ::Backups.status
        [ item(key: "local", status: local.nil? ? "warn" : (local < ::Integrations::SystemPlugin::BACKUP_LATE.ago ? "error" : "ok"), at: local,
               title: "Cópia diária no servidor", detail: local ? "Última: #{I18n.l(local, format: :short)}" : "Sem pasta de backup neste servidor"),
          offsite(s), restore(s) ]
      end

      def self.offsite(s)
        return item(key: "offsite", status: "warn", title: "Cópia fora de casa", detail: "Não configurada (docs/backup.md)") unless ::Backups.configured?

        at = ::Backups.time("uploaded_at")
        detail = [ s["destination"], ("última #{I18n.l(at, format: :short)}" if at), ("falhou: #{s['error']}" if s["error"]) ].compact.join(" · ")
        item(key: "offsite", status: ::Backups.offsite_ok? ? "ok" : "error", title: "Cópia fora de casa", at: at, detail: detail.presence || "Ainda não rodou")
      end

      def self.restore(s)
        return item(key: "restore", status: "warn", title: "Teste de restauração", detail: "Sem cópia externa") unless ::Backups.configured?

        at = ::Backups.time("restored_at")
        status = if ::Backups.restore_ok? then "ok"
        elsif s["restore_error"] then "error"
        else "warn"
        end
        detail = [ ("último ok #{I18n.l(at, format: :short)}" if at), ("falhou: #{s['restore_error']}" if s["restore_error"]) ].compact.join(" · ")
        item(key: "restore", status: status, title: "Teste de restauração", at: at, detail: detail.presence || "Ainda não rodou (domingo, 5h)")
      end
    end

    class Disk < Check
      describe key: "disk", label: "Disco", icon: "archive"

      def self.items(_tenant)
        d = ::Integrations::SystemPlugin.disk
        return [ item(key: "disk", status: "warn", title: "Disco", detail: "Não deu para ler") ] unless d

        status = d[:used] >= 90 ? "error" : (d[:used] >= 80 ? "warn" : "ok")
        [ item(key: "disk", status: status, title: "Disco", detail: "#{d[:used]}% usado · #{d[:free]} GB livres") ]
      end
    end

    # Versão e tempo no ar (deste processo).
    class Runtime < Check
      describe key: "runtime", label: "Versão e tempo no ar", icon: "information-circle"

      def self.items(_tenant)
        version = ENV["APP_VERSION"].presence&.first(12) || "desenvolvimento"
        [ item(key: "version", status: "ok", title: "Versão", detail: "#{version} · Ruby #{RUBY_VERSION} · Rails #{Rails.version}"),
          item(key: "uptime", status: "ok", title: "No ar desde", at: BOOTED_AT,
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
      DIVERGENT = %w[different missing extra].freeze

      def self.items(_tenant)
        Site.order(:name).filter_map do |site|
          report = ShadowReport.where(site_id: site.id).recent.first
          on = ::Shadow.site?(site)
          next unless report || on

          next item(key: site.id, status: "warn", title: site.name, detail: "Em sombra, sem comparação ainda") unless report

          div = divergences(report)
          item(key: site.id, status: div.zero? ? "ok" : "warn", title: site.name, at: report.created_at,
               detail: "#{on ? 'Em sombra' : 'Fora da sombra'} · última comparação #{I18n.l(report.created_at, format: :short)}: " +
                       (div.zero? ? "sem divergência" : "#{div} divergência(s)"))
        end.presence || [ item(key: "none", status: "ok", title: "Sombra", detail: "Nenhum local em sombra") ]
      end

      def self.divergences(report) = DIVERGENT.sum { |k| report.summary[k].to_i }
    end

    # O que falta para trocar o Home Assistant (ou outro sistema) por este (docs/cutover.md). Só informa.
    class Cutover < Check
      describe key: "cutover", label: "Pronto para a troca", icon: "check-circle", alerts: false

      def self.items(tenant) = ::Cutover.items(tenant)
    end
  end
end
