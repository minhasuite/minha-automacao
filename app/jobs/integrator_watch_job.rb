# Central do integrador (Integrator::Watch, a cada minuto): sem sinal, problemas e "voltou" de cada instalação.
class IntegratorWatchJob < ApplicationJob
  queue_as :default
  queue_with_priority 10

  def perform = Integrator::Watch.tick
end
