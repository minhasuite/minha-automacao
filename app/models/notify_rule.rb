# Aviso (ESQUEMA-V1 §4.5, G4: push ao abrir/fechar o portão): o ponto mudou
# (ou chegou em `to_value`) → notificação nos canais escolhidos. Vai para os
# administradores. `priority` = nível (crítico fura o horário de silêncio);
# `merge_s` = janela para juntar avisos seguidos do ponto (nil = a da
# instalação, 0 = não junta; Notifications::Merge).
# `message` é Liquid com o contexto das automações (`MessageTemplate`;
# {ponto} e {valor} continuam valendo).
class NotifyRule < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  belongs_to :site
  belongs_to :point

  before_validation { self.site_id ||= point&.site_id }
  before_validation { self.to_value = point.cast(to_value) if point && to_value.is_a?(String) }
  before_validation { self.channels = Array(channels).compact_blank }

  validates :priority, inclusion: { in: Notifications::LEVELS }
  validates :merge_s, numericality: { only_integer: true, in: 0..6.hours.to_i }, allow_nil: true
  validates :message, length: { maximum: MessageTemplate::MAX }
  validate { (e = MessageTemplate.syntax_error(message)) && errors.add(:message, :invalid_template, error: e) }
  validate :channels_fit
  validate { errors.add(:point, :other_site) if point && point.site_id != site_id }

  audited_attributes :enabled, :to_value, :channels, :priority, :merge_s

  def self.fire(point)
    where(point_id: point.id, enabled: true).find_each { |r| r.deliver(point) if r.to_value.nil? || r.to_value == point.value }
  end

  def deliver(point)
    window = merge_s.nil? ? Notifications.merge_window(tenant) : merge_s
    Notifier.deliver!(channels, kind: "aviso", title: title_for(point),
                                data: { point_id: point.id, site_id: point.site_id, priority: priority, merge_key: "notify_rule:#{id}",
                                        merge_s: window, merge_subject: point.name })
  end

  # Texto do aviso: a mensagem (Liquid) ou "Ponto: valor". Modelo com erro na
  # hora de avisar não cala o aviso: vai o texto padrão.
  def title_for(point)
    default = "#{point.name}: #{ApplicationController.helpers.point_value_text(point)}"
    return default if message.blank?

    MessageTemplate.render(site, message, trigger: MessageTemplate.point_trigger(point)).squish.presence || default
  rescue Automations::Context::Error => e
    Rails.logger.info("[aviso] texto com erro: #{e.message}")
    default
  end

  # Prévia do formulário com o valor atual do ponto: [texto, erro].
  def preview
    return [ nil, nil ] unless point

    return [ title_for(point), nil ] if message.blank?

    MessageTemplate.preview(site || point.site, message, trigger: MessageTemplate.point_trigger(point))
  end

  private

  def channels_fit
    errors.add(:channels, :none) unless Notifier.valid_channels?(channels)
  end
end
