require "digest"

# Chave de integração servidor-a-servidor (header X-Api-Key), criada pelo dono
# para outro sistema (ex.: o minhas-vendas mudando o preço num e-ink). Vale só
# nos locais de `site_ids` e só para as permissões de `scopes`:
#   read    → ler locais, dispositivos, pontos e histórico
#   command → mandar comando a um ponto (papel × risco continuam valendo)
#   write   → escrever o valor de um ponto virtual (POST /points/:id/value)
# Guarda só o digest; a chave em claro aparece uma vez, na criação.
class ServiceApiKey < ApplicationRecord
  belongs_to :user

  SCOPES = { "read" => "Ler", "command" => "Comandar", "write" => "Escrever valor em pontos" }.freeze
  KNOWN_SCOPES = SCOPES.keys.freeze

  validates :name, presence: true
  validate :scopes_known
  validate :sites_of_the_installation

  normalizes :name, with: ->(v) { v.to_s.squish }

  scope :active, -> { where(revoked_at: nil) }
  scope :of_tenant, ->(tenant) { joins(:user).where(users: { tenant_id: tenant.id }) }

  def self.issue(user, name:, scopes:, site_ids:, expires_at: nil)
    plain = "svc_#{SecureRandom.urlsafe_base64(32)}"
    key = create!(user: user, name: name.to_s, scopes: Array(scopes).map(&:to_s).compact_blank.uniq,
                  site_ids: Array(site_ids).compact_blank.uniq, token_digest: digest(plain), expires_at: expires_at)
    [ key, plain ]
  end

  def self.find_by_token(plain)
    return if plain.blank?

    active.where(token_digest: digest(plain)).where("expires_at IS NULL OR expires_at > ?", Time.current).first
  end

  def self.digest(plain) = Digest::SHA256.hexdigest(plain.to_s)

  def touch_usage!
    update_column(:last_used_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def expired? = expires_at.present? && expires_at <= Time.current
  def revoke! = update!(revoked_at: Time.current)

  private

  def scopes_known
    errors.add(:scopes, "escolha ao menos uma permissão") if scopes.empty?
    errors.add(:scopes, "tem permissão desconhecida") unless (scopes - KNOWN_SCOPES).empty?
  end

  def sites_of_the_installation
    return errors.add(:site_ids, "escolha ao menos um local") if site_ids.empty?

    known = ActsAsTenant.without_tenant { Site.where(tenant_id: user&.tenant_id, id: site_ids).count }
    errors.add(:site_ids, "tem local que não é desta instalação") unless known == site_ids.size
  end
end
