module Assist
  module Intents
    # Tempo (HassGetWeather): o primeiro ponto de clima exposto (integração de previsão).
    class Weather < Intent
      describe key: "get_weather", slots: %w[name],
               description: "Diz o tempo agora pela integração de previsão do tempo.",
               sentences: { "pt-BR" => [ "como (esta|vai) o tempo [hoje|agora|la fora|ai fora]", "(qual|como) [e|esta] a previsao [do tempo] [(para|de) (hoje|amanha)]",
                                         "vai chover [hoje|amanha]", "como esta o clima [hoje|agora]" ],
                            "en" => [ "what (is|s) the weather [like] [today|now|outside]", "how (is|s) the weather [today]", "is it going to rain [today|tomorrow]",
                                      "what (is|s) the forecast [for today]" ],
                            "es" => [ "que tiempo hace [hoy|ahora|afuera]", "como esta el (tiempo|clima) [hoy]", "cual es el pronostico [de hoy|para hoy]",
                                      "va a llover [hoy|manana]" ] }
      texts "pt-BR" => { now: "%{name}: %{value}." },
            en: { description: "Tells the current weather from the forecast integration.", now: "%{name}: %{value}." },
            es: { description: "Dice el tiempo actual con la integración de pronóstico.", now: "%{name}: %{value}." }

      def self.handle(ctx, slots)
        all = Assist.exposed(ctx.site.points.where(capability: "weather"))
        point = (slots["name"].present? && Assist.find_points(ctx.site, slots["name"]).find { |p| p.capability == "weather" }) || all.first or return
        reply(text(:now, name: point.name, value: point.quality == "good" ? Assist.value_text(point) : State::Read.text(:no_signal)), points: [ point ])
      end
    end
  end
end
