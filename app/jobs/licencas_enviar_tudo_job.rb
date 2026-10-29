# Reenvia à central todas as assinaturas que existem (rake `licencas:enviar_tudo`
# e recorrente diário): o informe do `recompute!` que falhou na rede não volta sozinho.
class LicencasEnviarTudoJob < ApplicationJob
  queue_as :default

  def perform
    return 0 unless Licencas::Client.enabled?

    tenants = Tenant.where(id: Subscription.select(:tenant_id)).or(Tenant.where(plan_provider: "manual"))
    tenants.find_each { |t| LicencasReportJob.perform_now(t.id) }
    tenants.count
  end
end
