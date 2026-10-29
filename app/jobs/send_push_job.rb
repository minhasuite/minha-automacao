# Push FCM de uma notificação: aparelhos da pessoa, ou dos administradores da empresa
# quando a notificação não tem dono.
class SendPushJob < ApplicationJob
  queue_as :default

  def perform(notification_id)
    return unless Push::FcmService.configured?

    notification = ActsAsTenant.without_tenant { Notification.find_by(id: notification_id) }
    return unless notification

    users = notification.user_id ? User.where(id: notification.user_id) : User.where(tenant_id: notification.tenant_id, role: %w[owner admin])
    DeviceToken.where(user: users).find_each do |device|
      result = Push::FcmService.deliver(device.token, title: notification.title, body: notification.body.to_s,
                                                      data: notification.data.merge("kind" => notification.kind, "notification_id" => notification.id))
      device.destroy if result == :unregistered
    end
  end
end
