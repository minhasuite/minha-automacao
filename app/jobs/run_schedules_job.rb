# Agendas vencidas (Schedule.run_due), a cada minuto pelo recurring.yml.
class RunSchedulesJob < ApplicationJob
  queue_as :default

  def perform = Schedule.run_due
end
