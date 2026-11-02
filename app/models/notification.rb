# Alerta in-app. Com `user` vai só para a pessoa (push nos aparelhos dela);
# sem `user` vai para os administradores da empresa. O push sai pelo Notifier
# (Push::TRANSPORTS). `dedup_key` impede repetir o mesmo alerta.
#
# Lote 1: o aviso pode ter botões (`data["actions"]`, até 3 {id, title}; com
# `point_id` + `command` (+ `value`) o botão também comanda o ponto),
# imagem (anexo `image`, com validade de IMAGE_TTL, ou `data["image_url"]`),
# link ao tocar (`data["url"]`) e opções de push (`priority`, `tag`, `ttl`,
# `sticky`, `group`). A resposta vale uma vez (`responded_at`/`response`) e
# vira o evento `notification_action` das automações.
class Notification < ApplicationRecord
  acts_as_tenant :tenant
  belongs_to :user, optional: true
  has_one_attached :image

  KINDS = %w[convite resumo_diario sistema aviso alerta automacao integracao].freeze
  MAX_ACTIONS = 3
  IMAGE_TTL = 7.days
  TOKEN_TTL = 7.days

  validates :kind, inclusion: { in: KINDS }
  validates :title, presence: true

  scope :unread, -> { where(read_at: nil) }
  # O que esta pessoa vê no sino: o que é dela e, se for admin, o da empresa.
  scope :for_user, ->(u) { u.admin? ? where(user_id: [ u.id, nil ]) : where(user_id: u.id) }
  scope :tagged, ->(tag) { where("notifications.data->>'tag' = ?", tag) }

  def actions = Array(data["actions"]).select { |a| a.is_a?(Hash) && a["id"].present? }.first(MAX_ACTIONS)
  def actionable? = actions.any? && responded_at.nil?
  def response_title = response && actions.find { |a| a["id"] == response["action"] }&.dig("title") || response&.dig("action")

  # Só caminho interno ("/paineis/...") ou http(s).
  def open_url
    url = data["url"].to_s.strip
    url if url.match?(%r{\A/(?![/\\])}) || url.match?(%r{\Ahttps?://}i)
  end

  # Imagem do aviso: anexo (quadro de câmera) por URL assinada que expira, ou a URL dada.
  def image_url
    return Rails.application.routes.url_helpers.push_image_path(t: signed_id(purpose: :push_image, expires_in: IMAGE_TTL)) if image.attached?

    url = data["image_url"].to_s.strip
    url if url.match?(%r{\Ahttps://}i) || url.match?(%r{\A/(?![/\\])})
  end

  # Token da resposta pelo service worker: assinado com a notificação e a
  # pessoa (não dá para responder pela outra) e de uso único (responded_at).
  def action_token(user) = self.class.action_verifier.generate([ id, user.id ], expires_in: TOKEN_TTL)

  def self.action_verifier = Rails.application.message_verifier(:notification_action)

  # [notificação, pessoa] do token, ou nil (inválido, vencido ou pessoa desativada).
  def self.from_action_token(token)
    id, user_id = action_verifier.verified(token.to_s)
    return unless id

    ActsAsTenant.without_tenant do
      n = find_by(id: id)
      user = User.find_by(id: user_id, disabled_at: nil)
      [ n, user ] if n && user && user.tenant_id == n.tenant_id && (n.user_id.nil? ? user.admin? : n.user_id == user.id)
    end
  end

  # Grava a resposta (uma vez só) e avisa as automações. => true | false (já respondida).
  def respond!(action_id, user)
    action = actions.find { |a| a["id"] == action_id.to_s } or raise ArgumentError, "ação desconhecida"
    now = Time.current
    resp = { "action" => action["id"], "user_id" => user.id, "user" => user.name, "at" => now.iso8601 }
    taken = self.class.where(id: id, responded_at: nil).update_all(responded_at: now, read_at: read_at || now, response: resp, updated_at: now) # rubocop:disable Rails/SkipsModelValidations
    return false unless taken == 1

    reload
    run_command(action, user)
    site_id = data["site_id"]
    Automations::Triggers.event(site_id, "notification_action", event_payload(action, user)) if site_id
    true
  end

  # Botão com comando (`point_id`, `command`, `value`): manda o comando como a
  # pessoa que tocou, com a mesma regra de papel x risco da API. Tocar no
  # botão é a confirmação; sem permissão ou com erro, só não manda (a
  # resposta e o evento seguem valendo).
  def run_command(action, user)
    return if action["point_id"].blank? || action["command"].blank?

    point = Point.find_by(id: action["point_id"]) or return
    role = point.site.role_for(user)
    return unless role && SiteMembership.allowed?(role, :command, risk: point.risk)

    Points::Command.call(point, action["command"], action["value"], source: "push", user: user)
  rescue Points::Command::Error => e # inclui o modo sombra (Shadow::Blocked)
    Rails.logger.info("[aviso] botão #{action['id']}: #{e.message}")
  end

  def event_payload(action, user)
    { "action" => action["id"], "title" => action["title"], "user_id" => user.id, "user" => user.name, "notification_id" => id,
      "run_id" => data["run_id"], "automation_id" => data["automation_id"], "data" => data.except("actions") }.compact
  end

  # Quadros de câmera vencidos (ReadingsMaintenanceJob, todo dia).
  def self.purge_old_images!(now = Time.current)
    ActsAsTenant.without_tenant do
      where(created_at: ...(now - IMAGE_TTL)).joins(:image_attachment).find_each { |n| n.image.purge }
    end
  end
end
