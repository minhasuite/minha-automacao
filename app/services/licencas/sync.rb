module Licencas
  # Plano comprado pela web (licencas.minhasuite.com/assinar/<slug>) com o
  # e-mail de algum membro: vira Subscription `source: "licencas"` e quem
  # decide o plano é o Entitlement. A central fora do ar não mexe em nada.
  module Sync
    STATUS = { "ativa" => "active", "teste" => "trial", "carencia" => "grace", "suspensa" => "on_hold",
               "cancelada" => "canceled", "expirada" => "expired", "pendente" => "pending" }.freeze

    module_function

    # GET /billing e Configurações: no máximo 1x/min por empresa.
    def throttled(tenant)
      return unless Client.enabled?

      Rails.cache.fetch("licencas:sync:#{tenant.id}", expires_in: 1.minute) { call(tenant) || true }
    rescue StandardError => e
      Rails.error.report(e, handled: true)
      nil
    end

    def call(tenant)
      emails = tenant.users.pluck(:email).compact_blank
      return if emails.empty?

      res = Client.rights(emails)
      return if res.nil?

      changed = expire_others(tenant, res.dig("data", "id_externo"))
      changed = upsert(tenant, res["data"]) || changed if res["data"]
      Billing::Entitlement.recompute!(tenant) if changed
      changed
    end

    def upsert(tenant, d)
      sub = Subscription.find_or_initialize_by(source: "licencas", external_id: d["id_externo"])
      previous = sub.tenant if sub.persisted? && sub.tenant_id != tenant.id
      sub.update!(tenant: tenant, user: tenant.users.find_by(email: d["email"].to_s.downcase), plan: Plans.normalize(d["plano"]),
                  base_plan_id: d["ciclo"], status: STATUS.fetch(d["status"].to_s, "expired"),
                  auto_renewing: d["renovacao_automatica"], expires_at: d["expira_em"].presence && Time.zone.parse(d["expira_em"]),
                  verified_at: Time.current)
      # A pessoa mudou de empresa: o plano vai com ela.
      Billing::Entitlement.recompute!(previous) if previous
      sub.saved_changes.except("verified_at", "updated_at").any?
    end

    # Nada valendo lá (ou valendo outra): a guardada só expira depois da
    # validade, que já vem com a folga de 3 dias. Nunca rebaixa antes.
    def expire_others(tenant, keep)
      stale = tenant.subscriptions.where(source: "licencas", status: Subscription::ENTITLING).where.not(external_id: keep.to_s)
      stale = stale.where(expires_at: nil).or(stale.where(expires_at: ...Time.current))
      stale.update_all(status: "expired", updated_at: Time.current).positive? # rubocop:disable Rails/SkipsModelValidations
    end
  end
end
