module Notifier
  module Channels
    # "No app": a notificação já criada é o aviso (sino e /notificacoes, com
    # botões, imagem e link). Entrega = nada além do registro.
    module InApp
      KEY = "in_app".freeze

      module_function

      def default = KEY
      def owns?(channel) = channel == KEY
      def choices(_site) = [ [ KEY, "No app" ] ]
      def label(_channel) = "No app"
      def capabilities = Notifier::FEATURES
      def deliver(_channel, _notifications) = nil
    end
  end
end
