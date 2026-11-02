module Assist
  module Intents
    module Clock
      # Hora (HassGetCurrentTime), no fuso da instalação.
      class Time < Intent
        describe key: "get_time",
                 description: "Diz a hora atual.",
                 sentences: { "pt-BR" => [ "que horas (sao|e) [agora]", "que hora e", "(me diga|me diz|diga|diz) [as] horas" ],
                              "en" => [ "what time is it [now]", "what (is|s) the time", "tell me the time" ],
                              "es" => [ "que hora es [ahora]", "(dime|me dices) la hora" ] }
        texts "pt-BR" => { now: "São %{time}." },
              en: { description: "Tells the current time.", now: "It's %{time}." },
              es: { description: "Dice la hora actual.", now: "Son las %{time}." }

        def self.handle(_ctx, _slots) = reply(text(:now, time: ::Time.current.strftime("%H:%M")))
      end

      # Data (HassGetCurrentDate).
      class Date < Intent
        describe key: "get_date",
                 description: "Diz a data de hoje.",
                 sentences: { "pt-BR" => [ "(que|qual) [e] (dia|data) [e] hoje", "qual [e] a data [de hoje]", "que dia e hoje" ],
                              "en" => [ "what (is|s) [the] (date|day) [today]", "what (is|s) today s date", "what day is it [today]" ],
                              "es" => [ "que (dia|fecha) es hoy", "cual es la fecha [de hoy]" ] }
        texts "pt-BR" => { now: "Hoje é %{date}." },
              en: { description: "Tells today's date.", now: "Today is %{date}." },
              es: { description: "Dice la fecha de hoy.", now: "Hoy es %{date}." }

        def self.handle(_ctx, _slots) = reply(text(:now, date: I18n.l(::Date.current, format: :long)))
      end
    end
  end
end
