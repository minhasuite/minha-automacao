# Cria a notificação in-app e manda o push (FCM). Com `user`, só para a
# pessoa; sem, para os administradores da empresa. `dedup_key` repetido = não cria
# de novo (devolve nil). `push: false` grava só a notificação.
module Notifier
  # Canais das regras de aviso e de alerta (F4). A notificação in-app sempre
  # nasce (é ela que o push leva); "push" liga o FCM.
  # F8: o canal "alexa" (anúncio nas Echos) entra aqui e em CHANNELS, pelo
  # driver alexa; as regras já guardam a lista de canais.
  CHANNELS = { "in_app" => "No app", "push" => "Push no celular" }.freeze

  module_function

  def deliver!(channels, **)
    notify!(**, push: channels.include?("push"))
  end

  def notify!(kind:, title:, user: nil, body: nil, data: {}, dedup_key: nil, push: true)
    return nil if dedup_key && Notification.exists?(dedup_key: dedup_key)

    notification = Notification.create!(kind: kind, user: user, title: title.to_s.truncate(200), body: body, data: data, dedup_key: dedup_key)
    SendPushJob.perform_later(notification.id) if push && FeatureFlag.on?("push")
    notification
  rescue ActiveRecord::RecordNotUnique
    nil
  end
end
