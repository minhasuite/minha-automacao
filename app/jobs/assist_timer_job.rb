# Fim de um timer por voz (AssistTimer). `stamp` = o `ends_at` agendado.
class AssistTimerJob < ApplicationJob
  queue_as :default

  def perform(timer_id, stamp)
    timer = ActsAsTenant.without_tenant { AssistTimer.find_by(id: timer_id) } or return
    ActsAsTenant.with_tenant(timer.tenant) { timer.finish_due!(stamp) }
  end
end
