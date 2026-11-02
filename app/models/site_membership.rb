# Papel da pessoa num local (ESQUEMA-V1 §4.1). ROLES em ordem crescente de poder.
# Visitante com validade: `expires_at` vencido = sem acesso. Leitor (`viewer`)
# só vê os painéis que o papel dele vê: não comanda, não abre cadastro nem
# configurações (os controllers liberados declaram `viewer_allowed?`).
class SiteMembership < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  class Forbidden < StandardError; end

  ROLES = %w[viewer guest operator resident technician owner].freeze
  ROLE_LABELS = { "viewer" => "Leitor", "guest" => "Visitante", "operator" => "Operador", "resident" => "Morador",
                  "technician" => "Técnico", "owner" => "Dono" }.freeze
  # Papel mínimo para cada ação; comando depende do risco do ponto.
  MIN_ROLE = { view: "viewer", manage: "technician", admin: "owner" }.freeze
  MIN_ROLE_BY_RISK = { "normal" => "guest", "sensitive" => "operator", "critical" => "resident" }.freeze

  belongs_to :site
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :site_id }
  validate :user_in_same_tenant

  audited_attributes :role, :expires_at, :area_ids

  scope :active, -> { where(expires_at: nil).or(where(expires_at: Time.current..)) }

  # action: :view, :manage (áreas, dispositivos, pontos), :admin (local e membros) ou :command (com risk:).
  def self.allowed?(role, action, risk: nil)
    min = action == :command ? MIN_ROLE_BY_RISK.fetch(risk.to_s, "owner") : MIN_ROLE.fetch(action)
    role.present? && ROLES.index(role) >= ROLES.index(min)
  end

  def self.role_label(role) = ROLE_LABELS.fetch(role.to_s, role)

  private

  def user_in_same_tenant
    errors.add(:user, "precisa ser da empresa") if user && user.tenant_id != tenant_id
  end
end
