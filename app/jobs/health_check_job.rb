# Saúde do sistema: a cada 10 min avisa os administradores de cada instalação
# do que está com erro (`Health.alert!`; um aviso por problema por dia).
class HealthCheckJob < ApplicationJob
  queue_as :default

  def perform
    Tenant.find_each { |t| Health.alert!(t) }
  end
end
