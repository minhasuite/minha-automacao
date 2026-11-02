module Automations
  module ActionTypes
    # "Falar" (Lote 3, G31/G12): só a fala, sem criar aviso no app nem push.
    # Os alvos são os canais de fala do Notifier (os que respondem a `speak`,
    # hoje "Falar na <Echo>"); canal de fala novo aparece aqui sozinho.
    class SpeakAction < Base
      describe key: "speak", label: "Falar", defaults: { "channels" => [], "chime" => true },
               fields: [ f("channels", :channels, "Onde falar", required: true, options: :speech, en: "Where to speak", es: "Dónde hablar"),
                         f("message", :template, "Texto", required: true, en: "Text", es: "Texto"),
                         f("chime", :bool, "Com o som de anúncio", en: "With the announcement chime", es: "Con el sonido de anuncio") ]
      texts "pt-BR" => { speech_only: "escolha só canais de fala." },
            en: { label: "Speak", speech_only: "choose only speech channels." }, es: { label: "Hablar", speech_only: "elige solo canales de voz." }

      def self.rules(node)
        Array(node["channels"]).all? { |c| Notifier.speech_channel?(c) } ? [] : [ text(:speech_only) ]
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
