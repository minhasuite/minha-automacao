module Automations
  module ActionTypes
    # "Falar" (Lote 3, G31/G12): só a fala, sem criar aviso no app nem push.
    # Os alvos são os canais de fala do Notifier (os que respondem a `speak`,
    # hoje "Falar na <Echo>"); canal de fala novo aparece aqui sozinho.
    class SpeakAction < Base
      describe key: "speak", label: "Falar", defaults: { "channels" => [], "chime" => true },
               fields: [ f("channels", :channels, "Onde falar", required: true, options: :speech), f("message", :template, "Texto", required: true),
                         f("chime", :bool, "Com o som de anúncio") ]

      def self.rules(node)
        Array(node["channels"]).all? { |c| Notifier.speech_channel?(c) } ? [] : [ "escolha só canais de fala." ]
      end

      def self.call(e, _path, node)
        text = e.ctx.render(node["message"]).squish
        raise Engine::Failure, "Texto vazio." if text.empty?

        where = node["channels"].map { |ch| Notifier.channel_label(ch) }.join(", ")
        title = "Falar: #{text.truncate(60)}"
        return [ title, "simulated", "Não falado (simulação) em #{where}." ] if e.dry_run?

        node["channels"].each { |ch| Notifier.channel_for(ch).speak(ch, text, chime: node["chime"] != false) }
        [ title, "ok", where ]
      rescue Points::Command::Error => ex
        raise Engine::Failure, "Falar: #{ex.message}"
      end
    end
  end
end
