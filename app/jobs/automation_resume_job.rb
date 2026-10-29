# Retoma uma execução de automação que estava esperando (tempo ou condição).
# `seq` muda a cada espera: job velho ou repetido não retoma.
class AutomationResumeJob < ApplicationJob
  queue_as :default

  def perform(run_id, seq)
    run = ActsAsTenant.without_tenant { AutomationRun.find_by(id: run_id) } or return
    ActsAsTenant.with_tenant(run.tenant) { Automations::Engine.resume(run, seq) }
  end
end
