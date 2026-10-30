module Push
  # Transporte FCM para os aparelhos do app nativo (DeviceToken), pelo
  # FcmService. Leva a mesma Push::Message em `data` (o app F7 monta a
  # notificação com botões, imagem, canal e grupo); token morto é apagado.
  module Fcm
    module_function

    def configured? = FcmService.configured?
    def capabilities = Notifier::FEATURES

    def deliver(user, message)
      h = message.to_h(capabilities)
      data = h.except("title", "body", "data", "actions").merge(h["data"]).merge("kind" => message.notification.kind, "notification_id" => message.notification.id)
      data["actions"] = h["actions"].to_json if h["actions"]
      user.device_tokens.find_each do |device|
        result = FcmService.deliver(device.token, title: h["title"], body: h["body"], data: data.compact)
        device.destroy if result == :unregistered
      end
    end

    def clear(user, tag)
      user.device_tokens.find_each do |device|
        device.destroy if FcmService.deliver_data(device.token, data: { "type" => "clear", "tag" => tag }) == :unregistered
      end
    end
  end
end
