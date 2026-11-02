# Padrão de tempo com segundos (ondaA1, A5): o disparo num segundo dentro do
# minuto, agendado pelo relógio (Automations::Triggers.tick).
class AutomationTickJob < ApplicationJob
  queue_as :default

  def perform(automation_id, index, at)
    automation = ActsAsTenant.without_tenant { Automation.find_by(id: automation_id) } or return
    ActsAsTenant.with_tenant(automation.tenant) { Automations.safely { Automations::Triggers.fire_tick(automation, index, at) } }
  end
end
