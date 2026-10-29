# Gatilho com `for` ("aberto por 5 min"): dispara se o ponto ficou no estado
# o tempo todo (carimbo `changed_at` igual ao da mudança).
class AutomationTriggerJob < ApplicationJob
  queue_as :default

  def perform(automation_id, index, stamp)
    automation = ActsAsTenant.without_tenant { Automation.find_by(id: automation_id) } or return
    ActsAsTenant.with_tenant(automation.tenant) { Automations::Triggers.fire_after_hold(automation, index, stamp) }
  end
end
