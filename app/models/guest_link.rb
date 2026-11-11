# Link de convidado/babá (ideia 11): abre `/convidado/:token` sem conta, com
# um painel simplificado (só os widgets marcados com `"guest": true`, sem
# menu). Papel no local: `viewer` (só vê) ou `guest` (comanda ponto de risco
# normal); crítico e sensível nunca (o guest não chega lá pelo papel, e o
# GuestController barra o crítico de novo). Expira (`TTLS`, até 7 dias), o dono
# do local revoga a qualquer hora e tudo fica na auditoria (criar, revogar e
# cada comando pelo link). Token só em digest; em claro só na resposta.
class GuestLink < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  ROLES = %w[viewer guest].freeze
  # Validades oferecidas (horas).
  TTLS = [ 2, 8, 24, 72, 168 ].freeze
  TOKEN_BYTES = 24

  belongs_to :site
  belongs_to :dashboard
  belongs_to :created_by, class_name: "User", optional: true

  validates :name, presence: true, length: { maximum: 80 }
  validates :role, inclusion: { in: ROLES }
  validate :dashboard_in_site

  normalizes :name, with: ->(v) { v.to_s.squish }
  audited_attributes :revoked_at

  scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s.strip)

  # => [link, token em claro] (a única vez que o token existe fora do digest).
  def self.generate!(site:, dashboard:, name:, role:, hours:, created_by:)
    token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
    hours = hours.to_i.presence_in(TTLS) || TTLS.first
    link = create!(site: site, dashboard: dashboard, name: name, role: role, created_by: created_by,
                   token_digest: digest(token), expires_at: hours.hours.from_now)
    [ link, token ]
  end

  # Sem tenant: quem abre o link não está logado.
  def self.find_valid(token)
    return if token.blank?

    ActsAsTenant.without_tenant { active.find_by(token_digest: digest(token)) }
  end

  def active? = revoked_at.nil? && expires_at.future?
  def role_label = SiteMembership.role_label(role)

  def revoke!
    update!(revoked_at: Time.current) if revoked_at.nil?
  end

  def touch_use!
    update_columns(last_used_at: Time.current, uses: uses + 1)
  end

  private

  def dashboard_in_site
    errors.add(:dashboard, :invalid) if dashboard && site && dashboard.site_id != site_id
  end
end
