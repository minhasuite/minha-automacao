# Convite para a instalação, por LINK de uso único (sem e-mail: SMTP é
# opcional). Quem convida copia o link na tela e manda pela conversa; o link
# abre o cadastro direto nesta instalação (`/convite/:token`). Vale 7 dias e
# uma vez só; guardamos só o digest. `site_id` + `site_role`: o local e o
# papel que a pessoa ganha ao aceitar (opcional).
class Invite < ApplicationRecord
  acts_as_tenant :tenant
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :accepted_by, class_name: "User", optional: true
  belongs_to :site, optional: true

  TTL = 7.days
  TOKEN_BYTES = 24

  validates :role, inclusion: { in: User::ROLES - %w[owner] }
  validates :site_role, inclusion: { in: SiteMembership::ROLES }, allow_nil: true

  scope :pending, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s.strip)

  # => [convite, token em claro] — a única vez que o token existe fora do digest.
  def self.generate!(created_by:, role: "member", site: nil, site_role: nil)
    token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
    invite = create!(created_by: created_by, role: role, site: site, site_role: (site_role if site),
                     code_digest: digest(token), expires_at: TTL.from_now)
    [ invite, token ]
  end

  # Busca sem tenant: quem abre o link ainda não está logado.
  def self.find_valid(token)
    return if token.blank?

    ActsAsTenant.without_tenant { pending.find_by(code_digest: digest(token)) }
  end

  # Cria a conta na instalação do convite (e o papel no local) e queima o link.
  def accept!(name:, email:, password:)
    ActsAsTenant.with_tenant(tenant) do
      transaction do
        user = User.create!(tenant: tenant, role: role, name: name, email: email, password: password.to_s)
        SiteMembership.create!(site: site, user: user, role: site_role) if site && site_role
        update!(accepted_at: Time.current, accepted_by: user)
        user
      end
    end
  end
end
