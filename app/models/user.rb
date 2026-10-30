# Pessoa da instalação (o tenant da suíte; na tela não há "empresa"). NÃO é tenant-scoped (a autenticação roda antes de
# existir tenant): filtre por tenant à mão — `tenant.users`, nunca User.all.
#
# Papéis: owner (dono, tudo), admin (administra a empresa, menos plano e
# exclusão), member (usa). Papéis por local virão em `site_memberships`.
class User < ApplicationRecord
  has_secure_password validations: false

  belongs_to :tenant
  has_many :api_tokens, dependent: :delete_all
  has_many :service_api_keys, dependent: :delete_all
  has_many :device_tokens, dependent: :delete_all
  has_many :push_subscriptions, dependent: :delete_all

  ROLES = %w[owner admin member].freeze
  ROLE_LABELS = { "owner" => "Dono", "admin" => "Administrador", "member" => "Membro" }.freeze

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }
  normalizes :name, with: ->(n) { n.to_s.squish }

  validates :name, presence: true
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email, uniqueness: { case_sensitive: false }
  validates :role, inclusion: { in: ROLES }
  validates :password, length: { minimum: 8, maximum: 72 }, allow_nil: true
  validate :has_some_credential

  generates_token_for :password_recovery, expires_in: 30.minutes do
    password_digest.to_s.last(10)
  end

  # Login Google (web e API): verifica o id_token contra o client web
  # (GOOGLE_CLIENT_ID) e acha a conta por google_uid/e-mail; cria a conta (e a
  # empresa) na primeira vez. Levanta VerificationError com token inválido.
  def self.from_google!(id_token)
    payload = Google::Auth::IDTokens.verify_oidc(id_token.to_s, aud: ENV["GOOGLE_CLIENT_ID"].to_s)
    email = payload["email"].to_s.downcase
    raise Google::Auth::IDTokens::VerificationError, "token sem e-mail" if email.blank?

    user = find_by(google_uid: payload["sub"]) || find_by(email: email)
    if user
      user.update!(google_uid: payload["sub"]) if user.google_uid.blank?
      return user
    end
    transaction do
      name = payload["name"].presence || email.split("@").first
      create!(tenant: Tenant.create!(name: "Casa de #{name.split.first}"), name: name, email: email, google_uid: payload["sub"])
    end
  end

  # Desativada: não entra (web, API, chave de integração) até ser reativada.
  def disabled? = disabled_at.present?

  def disable!
    transaction do
      update!(disabled_at: Time.current)
      api_tokens.active.update_all(revoked_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def owner? = role == "owner"
  def admin? = role.in?(%w[owner admin])
  def role_label = ROLE_LABELS.fetch(role, role)

  private

  def has_some_credential
    errors.add(:password, :blank) if password_digest.blank? && google_uid.blank?
  end
end
