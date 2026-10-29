# IA — defaults de tier (fallback do código). A fonte da verdade é a tabela
# AiTierConfig, editável no painel admin. Sem a chave do provedor do tier, a
# IA daquele tier fica desligada e o app mostra só o cadastro manual.
#
#   light    → IAs do plano Pro
#   standard → IAs do plano Max
#   deep     → reservado; nenhuma feature usa hoje
#
# Padrão: Anthropic (ANTHROPIC_API_KEY) — Pro no light (Haiku 5.5), Max no
# standard (Sonnet 5.5); ver AiPlanFeature.
Rails.application.configure do
  config.x.ai = ActiveSupport::OrderedOptions.new
  config.x.ai.tiers = {
    light: { provider: "anthropic", model: "claude-haiku-5-5" },
    standard: { provider: "anthropic", model: "claude-sonnet-5-5", effort: "medium" },
    deep: { provider: "gemini", model: "gemini-3.1-pro-preview", effort: "high" }
  }
end
