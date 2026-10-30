module Notifier
  module Channels
    # "Push no celular": os aparelhos de cada pessoa, por todos os transportes
    # ligados (Push::TRANSPORTS: Web Push da PWA e FCM do app). O que cada
    # transporte suporta está em `capabilities` dele (Push::Message corta o resto).
    module Push
      KEY = "push".freeze

      module_function

      def default = KEY
      def owns?(channel) = channel == KEY
      def choices(_site) = [ [ KEY, "Push no celular" ] ]
      def label(_channel) = "Push no celular"
      def capabilities = ::Push::TRANSPORTS.flat_map { |t| ::Push.const_get(t).capabilities }.uniq

      def deliver(_channel, notifications)
        return unless FeatureFlag.on?("push")

        notifications.each { |n| SendPushJob.perform_later(n.id) }
      end

      def clear(notification, tag)
        SendPushJob.perform_later(notification.id, clear_tag: tag) if FeatureFlag.on?("push")
      end
    end
  end
end
