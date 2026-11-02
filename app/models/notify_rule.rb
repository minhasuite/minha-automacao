# Aviso (ESQUEMA-V1 §4.5, G4: push ao abrir/fechar o portão): o ponto mudou
# (ou chegou em `to_value`) → notificação nos canais escolhidos. Vai para os
# administradores (destinatários e horário de silêncio ficam para depois).
# `message` aceita {ponto} e {valor}.
class NotifyRule < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  belongs_to :site
  belongs_to :point

  before_validation { self.site_id ||= point&.site_id }
  before_validation { self.to_value = point.cast(to_value) if point && to_value.is_a?(String) }
  before_validation { self.channels = Array(channels).compact_blank }

  validates :message, length: { maximum: 200 }
  validate :channels_fit
  validate { errors.add(:point, :other_site) if point && point.site_id != site_id }

  audited_attributes :enabled, :to_value, :channels

  def self.fire(point)
    where(point_id: point.id, enabled: true).find_each { |r| r.deliver(point) if r.to_value.nil? || r.to_value == point.value }
  end

  def deliver(point)
    text = ApplicationController.helpers.point_value_text(point)
    title = message.presence ? message.gsub("{ponto}", point.name).gsub("{valor}", text) : "#{point.name}: #{text}"
    Notifier.deliver!(channels, kind: "aviso", title: title, data: { point_id: point.id, site_id: point.site_id })
  end

  private

  def channels_fit
    errors.add(:channels, :none) unless Notifier.valid_channels?(channels)
  end
end
