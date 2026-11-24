# Instalação → central do integrador (Integrator, a cada 5 min): o resumo da casa. Sem INTEGRATOR_URL/TOKEN, nada.
class IntegratorReportJob < ApplicationJob
  queue_as :default
  queue_with_priority 10

  def perform
    return unless Integrator.reporting?

    Integrator.send_report!
  rescue Integrator::Error => e
    Rails.logger.warn("[integrador] resumo não saiu: #{e.message}")
  end
end
