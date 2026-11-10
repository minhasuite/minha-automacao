# Execuções sem dono (Automations::Sweeper, docs/confiabilidade.md). No início
# do worker vem com o instante do início (o que rodava antes dele morreu com o
# processo anterior); na agenda (a cada 5 min), sem argumento: limite
# `Reliability.run_max` (15 min).
class AutomationSweepJob < ApplicationJob
  queue_as :default

  def perform(stale_before = nil)
    Automations::Sweeper.sweep!(stale_before: stale_before && Time.zone.parse(stale_before.to_s))
  end
end
