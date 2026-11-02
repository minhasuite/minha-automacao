# Assistente "Migre do HA" (Integrations::HaMigration): `fetch` lê o HA e
# monta a revisão; `import` importa o escolhido e guarda o relatório. O
# estado (com o erro, se der) fica em `integration.settings["migration"]`.
class HaMigrationJob < ApplicationJob
  queue_as :default

  def perform(integration_id, phase, choice = {})
    integration = ActsAsTenant.without_tenant { Integration.find_by(id: integration_id) } or return
    ActsAsTenant.with_tenant(integration.tenant) do
      m = Integrations::HaMigration
      if phase == "fetch"
        preview = m.preview(integration.site, m.fetch(integration))
        m.save_state!(integration, { "status" => "preview", "preview" => preview, "fetched_at" => Time.current.iso8601 })
      else
        report = m.run!(integration, choice)
        m.save_state!(integration, m.state(integration).merge("status" => "done", "report" => report, "finished_at" => Time.current.iso8601))
      end
    rescue Integrations::Error, SafeHttp::Error, Psych::Exception, ActiveRecord::RecordInvalid => e
      m.save_state!(integration.reload, m.state(integration).merge("status" => "failed", "error" => e.message.truncate(200), "phase" => phase))
    end
  end
end
