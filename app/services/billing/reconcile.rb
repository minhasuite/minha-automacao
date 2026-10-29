module Billing
  # De hora em hora (config/recurring.yml): reconsulta na Play as assinaturas
  # que dizem valer mas cuja validade passou (renovação sem RTDN) e recalcula
  # o plano das empresas. Também pergunta à central as vendidas pela web.
  module Reconcile
    module_function

    def call
      stale = Subscription.where(source: "play", status: Subscription::ENTITLING, expires_at: ...Time.current)
      stale.find_each do |sub|
        PlaySync.call(sub.external_id)
      rescue PlaySync::Error, GooglePlay::Error => e
        Rails.logger.warn("[billing] reconciliação de #{sub.id}: #{e.message}")
      end
      # Venda pela web: a central diz o que vale (só quem já tem assinatura de lá).
      Tenant.where(id: Subscription.where(source: "licencas").select(:tenant_id)).find_each { |t| Licencas::Sync.call(t) } if Licencas::Client.enabled?
      Tenant.where(plan_provider: %w[play licencas], plan_expires_at: ...Time.current).find_each { |t| Entitlement.recompute!(t) }
    end
  end
end
