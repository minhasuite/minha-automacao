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
  has_many :passkeys, dependent: :delete_all
  encrypts :otp_secret

  ROLES = %w[owner admin member].freeze
  ROLE_LABELS = LocalizedLabel.for("labels.user_roles", ROLES)

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }
  normalizes :name, with: ->(n) { n.to_s.squish }

  validates :name, presence: true
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email, uniqueness: { case_sensitive: false }
  validates :role, inclusion: { in: ROLES }
  validates :password, length: { minimum: 8, maximum: 72 }, allow_nil: true
  validate :has_some_credential
  validate :within_plan, on: :create

  generates_token_for :password_recovery, expires_in: 30.minutes do
    password_digest.to_s.last(10)
  end

  # Login Google (web e API; GoogleLogin confere o id_token). Acha a conta pelo
  # Google vinculado ou pelo e-mail verificado (e vincula); senão cria: no
  # convite, na instalação dele; sem convite, uma instalação nova (como criar
  # conta). E-mail de uma conta já vinculada a OUTRO Google é recusado.
  def self.from_google!(id_token, invite: nil)
    payload = GoogleLogin.verify!(id_token)
    sub = payload["sub"].to_s
    email = payload["email"].to_s.downcase
    user = find_by(google_uid: sub) || find_by(email: email)
    if user
      raise GoogleLogin::Error, "e-mail vinculado a outra conta Google" if user.google_uid.present? && user.google_uid != sub

      user.update!(google_uid: sub) if user.google_uid.blank?
      return user
    end

    name = payload["name"].presence || email.split("@").first
    return invite.accept!(name: name, email: email, google_uid: sub) if invite

    transaction do
      tenant = Tenant.create!(name: I18n.t("onboarding.account.tenant_name", name: name.split.first))
      create!(tenant: tenant, name: name, email: email, google_uid: sub)
    end
  end

  # Configurações → Segurança: vincula o Google do token a esta conta.
  def link_google!(id_token)
    sub = GoogleLogin.verify!(id_token)["sub"].to_s
    raise GoogleLogin::Error, "Google vinculado a outra conta" if User.where.not(id: id).exists?(google_uid: sub)

    update!(google_uid: sub)
  end

  # Desvincular só com outro jeito de entrar (senha ou passkey). → true/false
  def unlink_google!
    return false unless password_digest.present? || passkeys.exists?

    update!(google_uid: nil)
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

  # Só Leitor em todos os locais em que tem papel: vê painéis, nada de cadastro nem configurações.
  def reader?
    return false if admin?

    roles = ActsAsTenant.with_tenant(tenant) { SiteMembership.where(user_id: id).active.pluck(:role) }
    roles.any? && roles.all?("viewer")
  end
  def role_label = ROLE_LABELS.fetch(role, role)

  private

  # Produto: limite de pessoas do plano (Licensing).
  def within_plan
    errors.add(:base, Licensing.message("users")) if tenant&.persisted? && !Licensing.allowed?(tenant, "users")
  end

  def has_some_credential
    errors.add(:password, :blank) if password_digest.blank? && google_uid.blank?
  end
end
