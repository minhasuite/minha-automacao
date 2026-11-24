module Integrator
  # Avisos da central sobre as instalações (só INTEGRATOR_HUB=1). Cada regra olha o último resumo (e quando ele
  # chegou); problema novo = um aviso ao integrador; problema que sumiu = "voltou". Os ativos ficam em
  # `installations.alerts` ({chave → desde}). Regra nova = linha em RULES (aberto/fechado). Queda de rede ou
  # desligamento que a instalação conta no resumo vira um aviso só (não é estado), pela `last_outage`.
  module Watch
    OFFLINE_AFTER = 15.minutes
    HOT_C = 90
    DISK_PCT = 85
    BACKUP_LATE = 36.hours
    QUEUE_LATE = 5

    # chave → ->(instalação, agora) → texto do problema ou nil.
    RULES = {
      "offline" => ->(i, now) { I18n.t("integrator.alerts.offline", since: I18n.l(i.last_seen_at, format: :short)) if i.last_seen_at && i.last_seen_at < now - OFFLINE_AFTER },
      "hot" => ->(i, _) { (t = i.server["temp"]) && t >= HOT_C ? I18n.t("integrator.alerts.hot", temp: t) : nil },
      "disk" => ->(i, _) { (d = i.server.dig("disk", "used")) && d >= DISK_PCT ? I18n.t("integrator.alerts.disk", used: d) : nil },
      "no_internet" => ->(i, _) { I18n.t("integrator.alerts.no_internet") if i.server["online"] == false },
      "backup_late" => ->(i, now) { Watch.backup_late(i, now) },
      "restore_failed" => ->(i, _) { I18n.t("integrator.alerts.restore_failed") if i.backup["restore_ok"] == false },
      "queue" => ->(i, _) { (q = i.server["queue_late"].to_i) >= QUEUE_LATE ? I18n.t("integrator.alerts.queue", n: q) : nil },
      "health" => ->(i, _) { Watch.health_errors(i) }
    }.freeze

    module_function

    def backup_late(i, now)
      at = i.backup["offsite_at"].presence || i.backup["local_at"].presence or return nil
      I18n.t("integrator.alerts.backup_late", at: I18n.l(Time.zone.parse(at), format: :short)) if Time.zone.parse(at) < now - BACKUP_LATE
    end

    def health_errors(i)
      bad = i.health.select { |_k, v| v.to_h["status"] == "error" }.keys
      I18n.t("integrator.alerts.health", checks: bad.map { |k| I18n.t("integrator.checks.#{k}", default: k) }.join(", ")) if bad.any?
    end

    # Problemas de agora: {chave → texto}.
    def problems(i, now = Time.current)
      return {} if i.last_seen_at.nil?

      RULES.filter_map { |key, rule| (msg = rule.call(i, now)) && [ key, msg ] }.to_h
    end

    def status_for(problems)
      return "offline" if problems.key?("offline")
      return "error" if (problems.keys & %w[hot no_internet restore_failed queue health]).any?

      problems.any? ? "warn" : "ok"
    end

    # Avalia uma instalação: avisa o que começou, o que voltou e a queda que ela contou. → os problemas.
    def evaluate!(i, now: Time.current)
      now_problems = problems(i, now)
      before = i.alerts.to_h
      (now_problems.keys - before.keys).each { |k| notify(i, I18n.t("integrator.notify.problem", name: i.name, problem: now_problems[k]), "#{i.id}:#{k}") }
      (before.keys - now_problems.keys - %w[last_outage_to]).each do |k|
        notify(i, I18n.t("integrator.notify.back", name: i.name, problem: I18n.t("integrator.labels.#{k}", default: k)), "#{i.id}:#{k}")
      end
      outage = i.server["last_outage"]
      if outage.is_a?(Hash) && outage["to"].present? && outage["to"] != before["last_outage_to"] && before.key?("last_outage_to")
        notify(i, I18n.t("integrator.notify.outage.#{outage['kind'] == 'off' ? 'off' : 'network'}", name: i.name,
                                                                                                    duration: ServerVitals.duration(outage["seconds"])), "#{i.id}:outage")
      end
      alerts = now_problems.keys.to_h { |k| [ k, before[k] || now.iso8601 ] }
      alerts["last_outage_to"] = outage.is_a?(Hash) ? outage["to"].to_s : before["last_outage_to"].to_s
      i.update!(alerts: alerts, status: i.last_seen_at ? status_for(now_problems) : "waiting")
      now_problems
    end

    def notify(i, title, tag)
      ActsAsTenant.with_tenant(i.tenant) do
        Notifier.notify!(kind: "sistema", title: title, data: { "url" => "/integrador/#{i.id}", "tag" => "integrador:#{tag}" })
      rescue Shadow::Blocked
        nil
      end
    end

    # O minuto da central: todas as instalações (sem sinal só aparece aqui) e a limpeza das amostras velhas.
    def tick(now = Time.current)
      return unless Integrator.hub?

      ActsAsTenant.without_tenant { Installation.includes(:tenant).to_a }.each { |i| ActsAsTenant.with_tenant(i.tenant) { evaluate!(i, now: now) } }
      InstallationSample.prune!(now) if now.min.zero?
    end
  end
end
