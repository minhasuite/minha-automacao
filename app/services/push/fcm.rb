module Push
  # Transporte FCM para os aparelhos do app nativo (DeviceToken), pelo
  # FcmService. Leva a mesma Push::Message em `data`; token morto é apagado.
  # Android (app F7): mensagem só de dados com `type: notification`, título e
  # corpo — o app monta a notificação (botões que respondem por
  # `POST /push/resposta` com o `token`, imagem, canal pela prioridade, tag e
  # grupo), inclusive com o app fechado. iOS: notificação do sistema + dados.
  module Fcm
    module_function

    def configured? = FcmService.configured?
    def capabilities = Notifier::FEATURES

    def deliver(user, message) = deliver_some(user, message, nil)

    # `ids` = só esses aparelhos (nova tentativa do SendPushJob). Devolve os que
    # falharam de forma passageira (Transient: conexão que nem abriu, 429/5xx);
    # erro de um aparelho não impede os outros.
    def deliver_some(user, message, ids)
      h = message.to_h(capabilities)
      data = h.except("title", "body", "data", "actions").merge(h["data"]).merge("kind" => message.notification.kind, "notification_id" => message.notification.id)
      data["actions"] = h["actions"].to_json if h["actions"]
      data = data.compact
      devices = user.device_tokens
      devices = devices.where(id: ids) if ids
      devices.filter_map do |device|
        result = if device.platform == "android"
                   FcmService.deliver_data(device.token, data: data.merge("type" => "notification", "title" => h["title"], "body" => h["body"]))
        else
                   FcmService.deliver(device.token, title: h["title"], body: h["body"], data: data)
        end
        device.destroy if result == :unregistered
        device.id if result == :retry
      rescue StandardError => e
        next device.id if Transient.retryable?(e)

        Rails.error.report(e, handled: true)
        nil
      end
    end

    def clear(user, tag)
      user.device_tokens.find_each do |device|
        device.destroy if FcmService.deliver_data(device.token, data: { "type" => "clear", "tag" => tag }) == :unregistered
      end
    end
  end
end
