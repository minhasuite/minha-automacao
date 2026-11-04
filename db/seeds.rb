# Seeds idempotentes. Em produção o boot roda só `db:prepare` (que semeia
# apenas na criação do banco); nada aqui é obrigatório para o app funcionar.
ModelPrice.seed_defaults!
FeatureFlag.seed_defaults!

load Rails.root.join("db/seeds/test_user.rb") if Rails.env.development?
