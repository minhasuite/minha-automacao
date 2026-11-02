module Notifier
  module Channels
    # "No app": a notificação já criada é o aviso (sino e /notificacoes, com
    # botões, imagem e link). Entrega = nada além do registro.
    module InApp
      KEY = "in_app".freeze
      extend PluginTexts
      texts "pt-BR" => { label: "No app" }, en: { label: "In the app" }, es: { label: "En la app" }

      module_function

      def default = KEY
      def owns?(channel) = channel == KEY
      def choices(_site) = [ [ KEY, text(:label) ] ]
      def label(_channel) = text(:label)
      def capabilities = Notifier::FEATURES
      def deliver(_channel, _notifications) = nil
    end
  end
end
