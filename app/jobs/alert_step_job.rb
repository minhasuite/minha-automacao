# Próxima etapa do escalonamento de um Alert (agendada no banco).
class AlertStepJob < ApplicationJob
  queue_as :default

  def perform(alert_id, level)
    alert = ActsAsTenant.without_tenant { Alert.find_by(id: alert_id) } or return
    ActsAsTenant.with_tenant(alert.tenant) { alert.step!(level) }
  end
end
