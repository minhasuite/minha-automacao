# Matriz plano × feature de IA: disponível?, tier e limite mensal (nil =
# ilimitado). Editável no painel admin; DEFAULTS é seed e fallback.
class AiPlanFeature < ApplicationRecord
  PLANS = Tenant::PLANS
  FEATURES = %w[ask daily_summary].freeze
  # A lista de features entra na chave: feature nova no deploy invalida o mapa
  # que ficou no Solid Cache (senão ela some até alguém editar a matriz).
  CACHE_KEY = "ai_plan_features/map/#{FEATURES.join(",")}".freeze

  # Grátis não tem IA (regra de cobrança da suíte): sem IA tudo funciona com
  # o texto padrão. Pro = tier light (Haiku); Max = standard (Sonnet), ~3x a cota.
  NONE = { tier: "light", limit: 0, available: false }.freeze
  def self.plans(pro, max = pro * 3) = { "free" => NONE, "pro" => { tier: "light", limit: pro, available: true }, "max" => { tier: "standard", limit: max, available: true } }
  DEFAULTS = {
    "ask" => plans(300),          # pergunta livre à IA (placeholder até o domínio chegar)
    "daily_summary" => plans(62)  # resumo diário no celular
  }.freeze

  validates :feature, presence: true, uniqueness: { scope: :plan }, inclusion: { in: FEATURES }
  validates :plan, inclusion: { in: PLANS }
  validates :tier, inclusion: { in: AiTierConfig::TIERS }, allow_blank: true
  validates :limit, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  after_commit { Rails.cache.delete(CACHE_KEY) }

  def self.map
    Rails.cache.fetch(CACHE_KEY) do
      base = DEFAULTS.deep_dup
      all.each { |r| (base[r.feature] ||= {})[r.plan] = { tier: r.tier, limit: r.limit, available: r.available } }
      base
    end
  end

  # => { tier:, limit: } ou nil (indisponível no plano)
  def self.rule_for(feature:, plan:)
    rule = map.dig(feature.to_s, plan.to_s)
    return nil if rule.nil? || rule[:available] == false

    { tier: (rule[:tier].presence || "light").to_sym, limit: rule[:limit] }
  end

  def self.seed_defaults!
    DEFAULTS.each do |feature, plans|
      plans.each do |plan, r|
        find_or_create_by!(feature: feature, plan: plan) { |rec| rec.assign_attributes(r) }
      end
    end
  end
end
