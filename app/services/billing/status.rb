module Billing
  # O que o servidor entende que a empresa tem (GET /billing, resposta do
  # verify e a tela de Configurações do web).
  module Status
    module_function

    def call(tenant, user)
      sub = current_subscription(tenant)
      { plan: Plans.normalize(tenant.plan), status: sub&.status, provider: tenant.plan_provider,
        expires_at: sub&.expires_at || tenant.plan_expires_at, auto_renewing: sub&.auto_renewing,
        product_id: sub&.product_id, base_plan: sub&.base_plan_id, trial: sub&.trial || false,
        purchased_by_me: sub.present? && sub.user_id == user.id, purchaser_name: sub&.user&.name,
        trial_eligible: tenant.subscriptions.where(source: "play").none?,
        limits: Plans.limits(tenant.plan), usage: usage(tenant), catalog: Plans.catalog }
    end

    # A que dá o plano atual; sem ela, a última (para mostrar "expirou").
    def current_subscription(tenant)
      subs = tenant.subscriptions.where.not(status: "replaced").includes(:user).to_a
      subs.select(&:entitling?).max_by { |s| [ Plans.rank(s.plan), s.expires_at || 1000.years.from_now ] } || subs.max_by(&:updated_at)
    end

    # IA usada no mês, por feature.
    def usage(tenant)
      ActsAsTenant.with_tenant(tenant) { { ai: AiPlanFeature::FEATURES.index_with { |f| AiUsage.count_for(f) } } }
    end
  end
end
