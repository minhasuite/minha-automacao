# Resolve o painel padrão de cada pessoa/papel do local e guarda no cache comum
# (Dashboards::Prewarm, com debounce pelo `touch`).
class DashboardPrewarmJob < ApplicationJob
  queue_as :default
  queue_with_priority 10 # depois dos comandos

  def perform(site_id)
    site = ActsAsTenant.without_tenant { Site.find_by(id: site_id) } or return
    ActsAsTenant.with_tenant(site.tenant) { Dashboards::Prewarm.run(site) }
  end
end
