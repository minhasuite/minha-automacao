module Billing
  # Plano da EMPRESA a partir de todas as assinaturas dela (do minhas-compras):
  # melhor direito vence (Max > Pro; empate, a validade mais longa). Nunca
  # rebaixa por webhook perdido: a validade vencida é reconsultada na Play
  # antes (Billing::Reconcile). Plano dado à mão no painel (`manual`) não é
  # tocado por aqui.
  class Entitlement
    def self.recompute!(tenant) = new(tenant).call

    def initialize(tenant)
      @tenant = tenant
    end

    def call
      best = @tenant.subscriptions.reload.select(&:entitling?).max_by { |s| [ Plans.rank(s.plan), s.expires_at || 1000.years.from_now ] }
      best && best.plan != Plans::DEFAULT ? grant(best) : revoke
      LicencasReportJob.perform_later(@tenant.id) if Licencas::Client.enabled?
      @tenant
    end

    private

    def grant(sub)
      # Cortesia do painel maior que a compra: fica a cortesia.
      return if @tenant.plan_provider == "manual" && Plans.rank(@tenant.plan) >= Plans.rank(sub.plan)

      # `licencas` = assinada pelo site (o app não manda gerenciar na Play).
      @tenant.update!(plan: sub.plan, plan_provider: sub.source == "licencas" ? "licencas" : "play", plan_expires_at: sub.expires_at)
    end

    # Chega aqui depois de consultar a Play (verificação, RTDN, reconciliação):
    # nenhuma assinatura valendo = Grátis. Validade vencida sem aviso de
    # renovação é reconsultada antes pela reconciliação (Billing::Reconcile).
    def revoke
      return if @tenant.plan_provider == "manual"
      return if @tenant.plan == Plans::DEFAULT && @tenant.plan_provider.nil?

      @tenant.update!(plan: Plans::DEFAULT, plan_provider: nil, plan_expires_at: nil)
    end
  end
end
