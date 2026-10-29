# Planos da assinatura (decisão do dono, 15/10/2026). O plano é da EMPRESA
# (Tenant#plan); quem decide o plano vigente é Billing::Entitlement. Regra da
# suíte: só se cobra IA — o resto do produto é grátis.
#   free: tudo sem IA.
#   pro:  IAs no tier light (Haiku).
#   max:  as mesmas IAs no tier standard (Sonnet), cotas ~3x.
# Cotas e tier de cada IA: AiPlanFeature (banco, editável no painel).
module Plans
  ALL = %w[free pro max].freeze
  DEFAULT = "free".freeze
  NAMES = { "free" => "Grátis", "pro" => "Pro", "max" => "Max" }.freeze
  TRIAL_DAYS = 14
  TRIAL_OFFER = "teste-14-dias".freeze

  # productId da Play → plano; preço (centavos BRL) só para tela e testes —
  # quem cobra é a Play.
  PRODUCTS = { "automacao_pro" => "pro", "automacao_max" => "max" }.freeze
  PRICES = {
    "pro" => { "mensal" => 4990, "anual" => 49_900 },
    "max" => { "mensal" => 9990, "anual" => 99_900 }
  }.freeze
  PERIODS = { "mensal" => "P1M", "anual" => "P1Y" }.freeze

  module_function

  def normalize(plan) = ALL.include?(plan.to_s) ? plan.to_s : DEFAULT
  def rank(plan) = ALL.index(normalize(plan))

  # O que o plano dá: cota mensal de cada IA (0 = não tem) e o tier.
  def limits(plan)
    p = normalize(plan)
    ai = AiPlanFeature::FEATURES.index_with do |f|
      rule = AiPlanFeature.rule_for(feature: f, plan: p)
      rule ? rule[:limit] : 0
    end
    { ai: ai, ai_tier: AiPlanFeature.rule_for(feature: "ask", plan: p)&.dig(:tier)&.to_s }
  end

  def catalog
    ALL.map do |p|
      prices = (PRICES[p] || {}).map do |bp, cents|
        row = { base_plan: bp, period: PERIODS[bp], price_cents: cents }
        row[:savings_percent] = (100 - (cents * 100.0 / (PRICES[p]["mensal"] * 12))).round if bp == "anual"
        row
      end
      { plan: p, name: NAMES[p], product_id: PRODUCTS.key(p), trial_days: p == DEFAULT ? 0 : TRIAL_DAYS,
        prices: prices, limits: limits(p) }
    end
  end
end
