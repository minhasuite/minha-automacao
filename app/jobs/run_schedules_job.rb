# Agendas vencidas (Schedule.run_due) e gatilhos de horário/sol das
# automações (F6), a cada minuto pelo recurring.yml.
class RunSchedulesJob < ApplicationJob
  queue_as :default

  def perform
    Schedule.run_due
    Integrations.tick # antes dos gatilhos: o "agora" das agendas já anda
    HelperTypes.tick # sensor calculado "a cada" (Lote 5)
    Points::Stale.tick # sensor parado em "aberto" há tempo demais
    Automations::Triggers.tick
    Notifications::Digest.tick # resumo diário de quem escolheu a hora
  end
end
