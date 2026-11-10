# Push de uma notificação nos aparelhos de quem recebe, por todos os
# transportes ligados (Push::TRANSPORTS: Web Push e FCM). Com `clear_tag`,
# só apaga o aviso com aquela tag dos aparelhos de quem recebeu essa notificação.
#
# Falha passageira (docs/confiabilidade.md): os aparelhos em que nada chegou
# (Transient) recebem nova tentativa em 5 s, 30 s e 2 min (`only` = só eles;
# `attempt` = qual tentativa é esta). Quem já recebeu não recebe de novo.
class SendPushJob < ApplicationJob
  queue_as :default

  def perform(notification_id, clear_tag: nil, only: nil, attempt: 1)
    notification = ActsAsTenant.without_tenant { Notification.find_by(id: notification_id) }
    return unless notification
    return Push.clear(Push.recipients(notification), clear_tag) if clear_tag

    failed = Push.deliver(notification, only: only)
    return if failed.empty?

    wait = Transient.wait(attempt)
    if wait
      self.class.set(wait: wait).perform_later(notification_id, only: failed, attempt: attempt + 1)
    else
      Rails.logger.warn("[push] #{notification_id}: desistiu depois de #{attempt} tentativas (#{failed.transform_values(&:size)})")
    end
  end
end
