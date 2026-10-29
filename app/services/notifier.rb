# Cria a notificação in-app e manda o push (FCM). Com `user`, só para a
# pessoa; sem, para os administradores da empresa. `dedup_key` repetido = não cria
# de novo (devolve nil). `push: false` grava só a notificação.
module Notifier
  module_function

  def notify!(kind:, title:, user: nil, body: nil, data: {}, dedup_key: nil, push: true)
    return nil if dedup_key && Notification.exists?(dedup_key: dedup_key)

    notification = Notification.create!(kind: kind, user: user, title: title.to_s.truncate(200), body: body, data: data, dedup_key: dedup_key)
    SendPushJob.perform_later(notification.id) if push && FeatureFlag.on?("push")
    notification
  rescue ActiveRecord::RecordNotUnique
    nil
  end
end
