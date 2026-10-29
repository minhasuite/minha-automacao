# Seeds idempotentes. Em produção o boot roda só `db:prepare` (que semeia
# apenas na criação do banco); a matriz de IA tem fallback no código, então
# nada aqui é obrigatório para o app funcionar.
AiTierConfig.seed_defaults!
AiPlanFeature.seed_defaults!
ModelPrice.seed_defaults!
FeatureFlag.seed_defaults!

load Rails.root.join("db/seeds/test_user.rb") if Rails.env.development?
