# Saúde do sistema: a cada 10 min avisa os administradores de cada instalação
# do que está com erro (`Health.alert!`; um aviso por problema por dia) e da
# bateria baixa dos aparelhos (`Diagnostics.notify!`).
class HealthCheckJob < ApplicationJob
  queue_as :default

  def perform
    Tenant.find_each do |t|
      Health.alert!(t)
      Diagnostics.notify!(t) # bateria baixa (uma vez por semana por aparelho, se o local liga o aviso)
    rescue StandardError => e
      Rails.logger.warn("[health] #{t.id}: #{e.class}: #{e.message}")
    end
  end
end
