require "digest"

# Token opaco da API: par access (30 min) + refresh (60 dias, rotacionado a
# cada uso, com detecção de reuso). Guarda só digests SHA-256. Não é
# tenant-scoped: a autenticação roda antes de fixar a empresa.
class ApiToken < ApplicationRecord
  belongs_to :user

  ACCESS_TTL = 30.minutes
  REFRESH_TTL = 60.days

  scope :active, -> { where(revoked_at: nil) }

  # => [registro, access_plain, refresh_plain]
  def self.issue(user, device_name: nil)
    access = generate_token
    refresh = generate_token
    token = create!(user: user, access_token_digest: digest(access), refresh_token_digest: digest(refresh),
                    access_expires_at: ACCESS_TTL.from_now, refresh_expires_at: REFRESH_TTL.from_now,
                    device_name: device_name.presence)
    [ token, access, refresh ]
  end

  def self.find_by_access(plain)
    return if plain.blank?

    active.where(access_token_digest: digest(plain)).where("access_expires_at > ?", Time.current).first
  end

  def self.find_by_refresh(plain)
    return if plain.blank?

    active.where(refresh_token_digest: digest(plain)).where("refresh_expires_at > ?", Time.current).first
  end

  # Refresh que casa com o digest ANTERIOR de um token ativo = alguém reusou
  # um token já rotacionado (indício de roubo).
  def self.reused(plain)
    return if plain.blank?

    active.find_by(previous_refresh_token_digest: digest(plain))
  end

  # Janela deslizante: cada rotação estende o refresh por mais 60 dias.
  def rotate!
    access = self.class.generate_token
    refresh = self.class.generate_token
    update!(previous_refresh_token_digest: refresh_token_digest,
            access_token_digest: self.class.digest(access), refresh_token_digest: self.class.digest(refresh),
            access_expires_at: ACCESS_TTL.from_now, refresh_expires_at: REFRESH_TTL.from_now,
            last_used_at: Time.current)
    [ access, refresh ]
  end

  def revoke! = update!(revoked_at: Time.current)

  def touch_usage!
    update_column(:last_used_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def self.generate_token = SecureRandom.urlsafe_base64(32)
  def self.digest(plain) = Digest::SHA256.hexdigest(plain.to_s)
end
