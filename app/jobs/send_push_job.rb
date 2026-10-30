# Push de uma notificação nos aparelhos de quem recebe, por todos os
# transportes ligados (Push::TRANSPORTS: Web Push e FCM). Com `clear_tag`,
# só apaga o aviso com aquela tag dos aparelhos de quem recebeu essa notificação.
class SendPushJob < ApplicationJob
  queue_as :default

  def perform(notification_id, clear_tag: nil)
    notification = ActsAsTenant.without_tenant { Notification.find_by(id: notification_id) }
    return unless notification

    clear_tag ? Push.clear(Push.recipients(notification), clear_tag) : Push.deliver(notification)
  end
end
