# Entrega do canal "push" do Notifier (Lote 1). Um aviso vira uma Push::Message
# por pessoa e cada transporte registrado em TRANSPORTS leva aos aparelhos dela:
# Web Push (PWA, Push::Browser) e FCM (app nativo, Push::Fcm). Transporte novo
# = classe com `configured?`, `capabilities` (o que entrega de Notifier::FEATURES),
# `deliver(user, message)` e `clear(user, tag)` +
# nome aqui; o Notifier e o SendPushJob não mudam.
module Push
  TRANSPORTS = %w[Browser Fcm].freeze
  PRIORITIES = LocalizedLabel.for("automations.notifier.priorities", %w[normal high critical])
  DEFAULT_TTL = 1.day.to_i

  module_function

  def transports = TRANSPORTS.map { |name| const_get(name) }.select(&:configured?)

  # Quem recebe: a pessoa da notificação ou, sem pessoa, o dono e os administradores.
  def recipients(notification)
    users = notification.user_id ? User.where(id: notification.user_id) : User.where(tenant_id: notification.tenant_id, role: %w[owner admin])
    users.where(disabled_at: nil)
  end

  def deliver(notification)
    list = transports
    recipients(notification).find_each do |user|
      message = Message.new(notification, user)
      list.each { |t| t.deliver(user, message) }
    end
  end

  # Apaga dos aparelhos o aviso com a tag (ação "Avisar" com "só apagar").
  def clear(users, tag)
    list = transports
    users.each { |user| list.each { |t| t.clear(user, tag) } }
  end
end
