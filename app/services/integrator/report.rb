module Integrator
  # O resumo que a instalação manda para a central (só contagens e situações; ver o topo de `Integrator`).
  # Reaproveita o que já existe: Saúde (`Health.run`), integração Sistema, `ServerVitals`, backups e versão.
  module Report
    SCHEMA = 1

    module_function

    def build(now: Time.current)
      tenants = ActsAsTenant.without_tenant { Tenant.all.to_a }
      system = Integrations::SystemPlugin
      vitals = ServerVitals.state
      backup = Backups.status
      {
        "schema" => SCHEMA,
        "at" => now.iso8601,
        "version" => { "tag" => Updates.current_tag, "commit" => Updates.current_commit, "channel" => Updates.channel },
        "server" => {
          "temp" => ServerVitals.temperature, "cpu" => system.cpu, "memory" => system.memory, "disk" => system.disk&.slice(:used, :free),
          "host_up_since" => system.booted_at&.iso8601, "app_up_since" => system::STARTED_AT.iso8601,
          "online" => vitals.fetch("online", true), "last_outage" => ServerVitals.last_outage(vitals)&.slice("kind", "from", "to", "seconds"),
          "queue_late" => queue_late
        },
        "backup" => {
          "local_at" => system.last_backup&.iso8601, "offsite_at" => backup["uploaded_at"], "offsite_error" => backup["error"].present?,
          "restored_at" => backup["restored_at"], "restore_ok" => (Backups.restore_ok?(now) if backup["restored_at"])
        },
        "health" => health(tenants),
        "house" => house(tenants, now)
      }
    end

    # Situação de cada verificação da Saúde (a pior entre as empresas) e quantos itens com problema; sem os textos.
    def health(tenants)
      tenants.flat_map { |t| Health.run(t) }.group_by { |r| r.check.key }.to_h do |key, results|
        items = results.flat_map(&:items).reject(&:ignored)
        [ key, { "status" => Health.worst(items.map(&:status)), "problems" => items.count(&:problem?) } ]
      end
    end

    def house(tenants, now)
      ActsAsTenant.without_tenant do
        ids = tenants.map(&:id)
        since = now - 24.hours
        { "sites" => Site.where(tenant_id: ids).count, "devices" => Device.where(tenant_id: ids, disabled: false).count,
          "points_unavailable" => Point.where(tenant_id: ids, quality: "unavailable", disabled: false, hidden: false).count,
          "commands_24h" => Command.where(tenant_id: ids).where(created_at: since..).count,
          "commands_failed_24h" => Command.where(tenant_id: ids, status: "failed").where(created_at: since..).count,
          "runs_failed_24h" => AutomationRun.where(tenant_id: ids, status: "failed", dry_run: false).where(created_at: since..).count,
          "ai_errors_24h" => AiCall.where(tenant_id: ids, status: "error").where(created_at: since..).count }
      end
    end

    # Comandos esperando a fila há mais de 1 minuto (worker parado ou atolado).
    def queue_late
      ActsAsTenant.without_tenant { Command.where(status: "pending").where(created_at: ...1.minute.ago).count }
    end
  end
end
