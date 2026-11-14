module Push
  # Transporte Web Push (VAPID) para os navegadores inscritos (PushSubscription):
  # a PWA no Android/Chrome, a PWA na tela inicial do iPhone (iOS 16.4+) e o
  # navegador do computador. Chaves em VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY
  # (geradas por bin/vapid-keys no .env); vazias = transporte desligado.
  # Inscrição morta (404/410) é apagada.
  module Browser
    module_function

    # Web Push não tem grupo nem barra de progresso: `group` e `progress` são ignorados.
    def capabilities = Notifier::FEATURES - %i[group progress]
    def public_key = ENV["VAPID_PUBLIC_KEY"].to_s
    def configured? = public_key.present? && ENV["VAPID_PRIVATE_KEY"].present?

    def deliver(user, message) = deliver_some(user, message, nil)

    # `ids` = só essas inscrições (nova tentativa). Devolve as que falharam de
    # forma passageira (Transient, docs/confiabilidade.md).
    def deliver_some(user, message, ids)
      # "unread": avisos não lidos da pessoa, para o selo do ícone (navigator.setAppBadge no service worker).
      payload = message.to_h(capabilities).merge("unread" => unread(user)).to_json
      subs = user.push_subscriptions
      subs = subs.where(id: ids) if ids
      subs.filter_map { |sub| sub.id if send_to(sub, payload, ttl: message.ttl, urgency: message.urgency) == :retry }
    end

    # Pede ao service worker para fechar o aviso com a tag.
    def clear(user, tag)
      payload = { "type" => "clear", "tag" => tag, "unread" => unread(user) }.to_json
      user.push_subscriptions.find_each { |sub| send_to(sub, payload, ttl: DEFAULT_TTL, urgency: "normal") }
    end

    def unread(user) = ActsAsTenant.with_tenant(user.tenant) { Notification.for_user(user).unread.count }

    # => true | false (inscrição removida ou falha) | :retry (falha passageira: nada chegou)
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
    rescue ::WebPush::TooManyRequests, ::WebPush::PushServiceError => e
      Rails.logger.warn("[webpush] #{sub.id}: #{e.class} (nova tentativa)")
      :retry
    rescue ::WebPush::Error, OpenSSL::OpenSSLError, SocketError, SystemCallError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => e
      Rails.logger.warn("[webpush] #{sub.id}: #{e.class} #{e.message.truncate(120)}")
      Transient.retryable?(e) ? :retry : false
    end
  end
end
