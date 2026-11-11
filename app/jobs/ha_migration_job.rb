# Assistente "Migre do HA" (Integrations::HaMigration): `fetch` lê o HA e
# monta a revisão; `import` importa o escolhido e guarda o relatório. O
# estado (com o erro, se der) fica em `integration.settings["migration"]`.
class HaMigrationJob < ApplicationJob
  include SlowJob

  def perform(integration_id, phase, choice = {})
    integration = ActsAsTenant.without_tenant { Integration.find_by(id: integration_id) } or return
    ActsAsTenant.with_tenant(integration.tenant) do
      m = Integrations::HaMigration
      if phase == "dashboards"
        r = Integrations::HaDashboards.call(integration.site, integration)
        result = { "status" => "done", "finished_at" => Time.current.iso8601, "list" => r.dashboards.map { |d| { "id" => d.id, "name" => d.name } },
                   "notes" => r.notes.first(300) }
        m.save_state!(integration.reload, m.state(integration).merge("dashboards" => result))
      elsif phase == "fetch"
        preview = m.preview(integration.site, m.fetch(integration))
        m.save_state!(integration, { "status" => "preview", "preview" => preview, "fetched_at" => Time.current.iso8601 })
      else
        report = m.run!(integration, choice)
        m.save_state!(integration, m.state(integration).merge("status" => "done", "report" => report, "finished_at" => Time.current.iso8601))
      end
    rescue Integrations::Error, SafeHttp::Error, Psych::Exception, ActiveRecord::RecordInvalid => e
      if phase == "dashboards"
        m.save_state!(integration.reload, m.state(integration).merge("dashboards" => { "status" => "failed", "error" => e.message.truncate(200) }))
      else
        m.save_state!(integration.reload, m.state(integration).merge("status" => "failed", "error" => e.message.truncate(200), "phase" => phase))
      end
    end
  end
end
