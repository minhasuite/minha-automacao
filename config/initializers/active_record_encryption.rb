# Chaves do `encrypts` (segredos de integração que vierem). Em
# produção vêm do env (AR_ENCRYPTION_*, no vault); sem elas, dev e teste usam
# chaves derivadas do secret_key_base. Produção sem chave não sobe.
if ENV["AR_ENCRYPTION_PRIMARY_KEY"].present?
  Rails.application.config.active_record.encryption.tap do |e|
    e.primary_key = ENV.fetch("AR_ENCRYPTION_PRIMARY_KEY")
    e.deterministic_key = ENV.fetch("AR_ENCRYPTION_DETERMINISTIC_KEY")
    e.key_derivation_salt = ENV.fetch("AR_ENCRYPTION_KEY_DERIVATION_SALT")
  end
elsif Rails.env.production? && ENV["SECRET_KEY_BASE_DUMMY"].blank?
  raise "AR_ENCRYPTION_* ausentes em produção"
else
  gen = ->(k) { Digest::SHA256.hexdigest("#{Rails.application.secret_key_base}/#{k}") }
  Rails.application.config.active_record.encryption.tap do |e|
    e.primary_key = gen.("primary")
    e.deterministic_key = gen.("deterministic")
    e.key_derivation_salt = gen.("salt")
  end
end
