# Refaz os helpers de origem "*" de um local (sensor calculado com consulta ao
# conjunto de pontos), com debounce pelo HelperTypes.refresh_star_later.
class HelperStarRefreshJob < ApplicationJob
  queue_as :default
  queue_with_priority 10 # depois dos comandos e do resto

  def perform(site_id)
    site = ActsAsTenant.without_tenant { Site.find_by(id: site_id) } or return
    ActsAsTenant.with_tenant(site.tenant) do
      HelperTypes.star_helpers(site.id).find_each { |h| HelperTypes.for(h)&.refresh!(h) }
    end
  end
end
