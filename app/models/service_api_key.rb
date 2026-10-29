require "digest"

# Chave de integração servidor-a-servidor (header X-Api-Key), ligada a um
# usuário. Escopos: placeholders de leitura e escrita até o domínio chegar
# (ESQUEMA-V1). Guarda só o digest.
class ServiceApiKey < ApplicationRecord
  belongs_to :user

  KNOWN_SCOPES = %w[read write].freeze

  scope :active, -> { where(revoked_at: nil) }

  def self.issue(user, name:, scopes:, expires_at: nil)
    valid = Array(scopes).map(&:to_s) & KNOWN_SCOPES
    raise ArgumentError, "nenhum escopo válido" if valid.empty?

    plain = "svc_#{SecureRandom.urlsafe_base64(32)}"
    [ create!(user: user, name: name.to_s, scopes: valid, token_digest: digest(plain), expires_at: expires_at), plain ]
  end

  def self.find_by_token(plain)
    return if plain.blank?

    active.where(token_digest: digest(plain)).where("expires_at IS NULL OR expires_at > ?", Time.current).first
  end

  def touch_usage!
    update_column(:last_used_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def self.digest(plain) = Digest::SHA256.hexdigest(plain.to_s)
end
