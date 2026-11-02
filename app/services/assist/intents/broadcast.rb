module Assist
  module Intents
    # Anúncio em todas as caixas de som (HassBroadcast): "avise em toda a casa que o jantar está pronto".
    class Broadcast < Intent
      describe key: "broadcast", slots: %w[message],
               description: "Fala uma mensagem em todas as caixas de som que anunciam.",
               sentences: { "pt-BR" => [ "(anunciar|anuncie|anuncia|avisar|avise|avisa|falar|fale|fala) (em toda a casa|na casa toda|para todos|pra todos|em todas as caixas) [que] {message}",
                                         "(anunciar|anuncie|anuncia) [que] {message}" ],
                            "en" => [ "(broadcast|announce) [that] {message}", "tell everyone [that] {message}" ],
                            "es" => [ "(anuncia|anunciar|difunde) [que] {message}", "(di|decir|avisa|avisar) a todos [que] {message}" ] }
      texts "pt-BR" => { done: "Anunciei em %{names}.", slots: { message: "O que falar" } },
            en: { description: "Says a message on every speaker that can announce.", done: "Announced on %{names}.", slots: { message: "What to say" } },
            es: { description: "Dice un mensaje en todos los altavoces que anuncian.", done: "Anuncié en %{names}.", slots: { message: "Qué decir" } }

      def self.handle(ctx, slots)
        message = Assist.original(ctx.heard, slots["message"].to_s).presence or return
        points = Assist.exposed(ctx.site.points.where(capability: "speaker")).select { |p| p.writable && Points::Command.commands_for(p).include?("announce") }
        run(ctx, points, "announce", message.first(Points::Command::MAX_SPEECH), done: :done)
      end
    end
  end
end
