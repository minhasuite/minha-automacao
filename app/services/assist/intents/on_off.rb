module Assist
  module Intents
    # Ligar, desligar e alternar (HassTurnOn, HassTurnOff, HassToggle): o
    # ponto, o aparelho, a área ou o andar inteiro pelo nome falado.
    module OnOff
      class Base < Intent
        def self.command = nil

        def self.handle(ctx, slots)
          phrase = [ slots["name"], slots["area"] ].compact.join(" ")
          points, how = Assist.find_points_how(ctx.site, phrase, area: ctx.area)
          points = points.select { |p| p.writable && Points::Command.commands_for(p).include?(command) }
          # "a luz do escritório" com várias: pergunta qual (o plural, o cômodo e o nome exato fazem todas).
          return Assist::Clarify.ask(ctx, self, points, command) if Assist::Clarify.ask?(slots["name"], how, points)

          run(ctx, points, command, done: :done)
        end
      end

      class On < Base
        describe key: "turn_on", slots: %w[name area],
                 description: "Liga um ponto, aparelho, área ou andar (luz, tomada, ventilador...).",
                 sentences: { "pt-BR" => [ "(ligar|liga|ligue|acender|acende|acenda) {name}" ],
                              "en" => [ "(turn|switch|power) on {name}", "(turn|switch) {name} on" ],
                              "es" => [ "(encender|enciende|encienda|prender|prende|prenda) {name}" ] }
        texts "pt-BR" => { done: "Liguei %{names}." },
              en: { description: "Turns on a point, device, area or floor (light, plug, fan...).", done: "Turned on %{names}." },
              es: { description: "Enciende un punto, aparato, área o piso (luz, enchufe, ventilador...).", done: "Encendí %{names}." }

        def self.command = "on"
      end

      class Off < Base
        describe key: "turn_off", slots: %w[name area],
                 description: "Desliga um ponto, aparelho, área ou andar.",
                 sentences: { "pt-BR" => [ "(desligar|desliga|desligue|apagar|apaga|apague) {name}" ],
                              "en" => [ "(turn|switch|power) off {name}", "(turn|switch) {name} off" ],
                              "es" => [ "(apagar|apaga|apague|desactivar|desactiva) {name}" ] }
        texts "pt-BR" => { done: "Desliguei %{names}." },
              en: { description: "Turns off a point, device, area or floor.", done: "Turned off %{names}." },
              es: { description: "Apaga un punto, aparato, área o piso.", done: "Apagué %{names}." }

        def self.command = "off"
      end

      class Toggle < Base
        describe key: "toggle", slots: %w[name area],
                 description: "Inverte (liga se está desligado e vice-versa).",
                 sentences: { "pt-BR" => [ "(alternar|alterne|alterna|inverter|inverta|inverte) {name}" ],
                              "en" => [ "toggle {name}" ],
                              "es" => [ "(alternar|alterna|alterne|conmutar|conmuta) {name}" ] }
        texts "pt-BR" => { done: "Alternei %{names}." },
              en: { description: "Toggles (on if off and vice versa).", done: "Toggled %{names}." },
              es: { description: "Invierte (enciende si está apagado y viceversa).", done: "Alterné %{names}." }

        def self.command = "toggle"
      end
    end
  end
end
