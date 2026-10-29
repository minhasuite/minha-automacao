# Informa ao licenciamento central as assinaturas da empresa (depois de cada
# Billing::Entitlement.recompute! e no retroativo `licencas:enviar_tudo`).
# As `licencas` nasceram lá e não voltam.
class LicencasReportJob < ApplicationJob
  queue_as :default

  STATUS = { "active" => "ativa", "trial" => "teste", "grace" => "carencia", "on_hold" => "suspensa", "paused" => "suspensa",
             "canceled" => "cancelada", "expired" => "expirada", "replaced" => "expirada", "pending" => "pendente" }.freeze

  def perform(tenant_id)
    return unless Licencas::Client.enabled?

    tenant = Tenant.find_by(id: tenant_id)
    return if tenant.nil?

    self.class.payloads(tenant).each { |p| Licencas::Client.report(p) }
  end

  def self.payloads(tenant)
    subs = tenant.subscriptions.where.not(source: "licencas").where.not(plan: Plans::DEFAULT).includes(:user).to_a
    rows = subs.map { |s| payload(tenant, s.user, canal: s.source, id_externo: s.external_id, plano: s.plan, ciclo: s.base_plan_id,
                                  status: STATUS.fetch(s.status, "expirada"), renovacao_automatica: s.auto_renewing,
                                  iniciada_em: s.created_at, expira_em: s.expires_at) }
    # Cortesia dada à mão no tenant, sem Subscription.
    if tenant.plan_provider == "manual" && tenant.plan != Plans::DEFAULT && subs.none? { |s| s.source == "manual" }
      rows << payload(tenant, nil, canal: "manual", id_externo: "manual-#{tenant.id}", plano: tenant.plan, ciclo: nil,
                                   status: "ativa", expira_em: tenant.plan_expires_at)
    end
    rows
  end

  def self.payload(tenant, buyer, ciclo:, **attrs)
    who = buyer || tenant.users.find_by(role: "owner") || tenant.users.order(:created_at).first
    ciclo = ciclo.presence_in(Plans::PERIODS.keys)
    { email: who&.email, nome: who&.name, dono_id: tenant.id, empresa_nome: tenant.name, usuarios: tenant.users.count,
      ciclo: ciclo, valor_centavos: ciclo && Plans::PRICES.dig(attrs[:plano], ciclo), **attrs }
      .transform_values { |v| v.respond_to?(:iso8601) ? v.iso8601 : v }
  end
end
