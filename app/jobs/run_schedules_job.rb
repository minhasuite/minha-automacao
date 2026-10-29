# Agendas vencidas (Schedule.run_due) e gatilhos de horário/sol das
# automações (F6), a cada minuto pelo recurring.yml.
class RunSchedulesJob < ApplicationJob
  queue_as :default

  def perform
    Schedule.run_due
    Automations::Triggers.tick
  end
end
