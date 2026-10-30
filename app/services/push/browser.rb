module Push
  # Transporte Web Push (VAPID) para os navegadores inscritos (PushSubscription):
  # a PWA no Android/Chrome, a PWA na tela inicial do iPhone (iOS 16.4+) e o
  # navegador do computador. Chaves em VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY
  # (geradas por bin/vapid-keys no .env); vazias = transporte desligado.
  # Inscrição morta (404/410) é apagada.
  module Browser
    module_function

    # Web Push não tem grupo de notificações: o `group` do aviso é ignorado.
    def capabilities = Notifier::FEATURES - %i[group]
    def public_key = ENV["VAPID_PUBLIC_KEY"].to_s
    def configured? = public_key.present? && ENV["VAPID_PRIVATE_KEY"].present?

    def deliver(user, message)
      payload = message.to_h(capabilities).to_json
      user.push_subscriptions.find_each { |sub| send_to(sub, payload, ttl: message.ttl, urgency: message.urgency) }
    end

    # Pede ao service worker para fechar o aviso com a tag.
    def clear(user, tag)
      payload = { "type" => "clear", "tag" => tag }.to_json
      user.push_subscriptions.find_each { |sub| send_to(sub, payload, ttl: DEFAULT_TTL, urgency: "normal") }
    end

    # => true | false (inscrição removida ou falha)
    def send_to(sub, payload, ttl:, urgency:)
      ::WebPush.payload_send(message: payload, endpoint: sub.endpoint, p256dh: sub.p256dh_key, auth: sub.auth_key, ttl: ttl, urgency: urgency,
                             vapid: { subject: ENV.fetch("VAPID_SUBJECT", "mailto:noreply@minhasuite.com"), public_key: public_key,
                                      private_key: ENV.fetch("VAPID_PRIVATE_KEY") },
                             open_timeout: 5, read_timeout: 10)
      sub.update_column(:last_used_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
      true
    rescue ::WebPush::ExpiredSubscription, ::WebPush::InvalidSubscription
      sub.destroy
      false
    rescue ::WebPush::Error, OpenSSL::OpenSSLError, SocketError, SystemCallError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => e
      Rails.logger.warn("[webpush] #{sub.id}: #{e.class} #{e.message.truncate(120)}")
      false
    end
  end
end
