# Ponto exposto numa ponte (integ): o mesmo "Expor para a Alexa", genérico
# para qualquer plugin de `Bridges::PLUGINS` (Matter…). Ponto de risco
# crítico (portão, fechadura, sirene) só entra com a confirmação explícita.
class BridgeExposure < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :site
  belongs_to :point

  attr_accessor :risk_confirmed

  normalizes :name, with: ->(v) { v.to_s.squish.presence }
  validates :name, length: { maximum: 60 }
  validates :bridge, inclusion: { in: ->(_) { Bridges.keys } }
  validates :point_id, uniqueness: { scope: :bridge }
  validate :critical_confirmed, on: :create

  def label = name.presence || point.name

  private

  def critical_confirmed
    return unless point&.risk == "critical"
    return if ActiveModel::Type::Boolean.new.cast(risk_confirmed)

    errors.add(:base, :confirm_critical, name: point.name)
  end
end
