module Assist
  module Intents
    # Robô aspirador (HassVacuumStart, HassVacuumReturnToBase). Sem nome: o
    # da área do satélite ou, se houver um só, ele.
    module Vacuum
      ROBOT = "(robo|aspirador|robozinho)".freeze

      class Base < Intent
        def self.command = nil

        def self.handle(ctx, slots)
          run(ctx, Assist.targets(ctx, slots["name"], "vacuum", command: command), command, done: :done)
        end
      end

      class Start < Base
        describe key: "vacuum_start", slots: %w[name],
                 description: "Começa a limpeza com o robô aspirador.",
                 sentences: { "pt-BR" => [ "(iniciar|inicie|inicia|comecar|comece|comeca) [a] limpeza", "(aspirar|aspire|aspira|limpar|limpe|limpa) a casa",
                                           "(mandar|mande|manda) [o] {name} (limpar|aspirar)", "(ligar|ligue|liga) [o] #{ROBOT}" ],
                              "en" => [ "start [the] (vacuum|vacuuming|cleaning)", "(vacuum|clean) the house", "start [the] {name}" ],
                              "es" => [ "(inicia|iniciar|empieza|empezar|comienza) [la] limpieza", "(aspira|aspirar|limpia|limpiar) la casa",
                                        "(enciende|encender|prende) [la|el] (aspiradora|robot)" ] }
        texts "pt-BR" => { done: "Comecei a limpeza com %{names}." },
              en: { description: "Starts cleaning with the robot vacuum.", done: "Started cleaning with %{names}." },
              es: { description: "Empieza la limpieza con el robot aspirador.", done: "Empecé la limpieza con %{names}." }

        def self.command = "start"
      end

      class Dock < Base
        describe key: "vacuum_dock", slots: %w[name],
                 description: "Manda o robô aspirador voltar para a base.",
                 sentences: { "pt-BR" => [ "(mandar|mande|manda) [o] (#{ROBOT[1..-2]}|{name}) (voltar|volta|ir) [para|pra] [a] base", "[o] #{ROBOT} (volta|voltar|vai) [para|pra] [a] base" ],
                              "en" => [ "(send|return) [the] (vacuum|robot|{name}) (home|to [the] (base|dock))", "[the] (vacuum|robot) go home" ],
                              "es" => [ "(manda|envia|enviar|mandar) [la|el] (aspiradora|robot|{name}) a [la] base", "[la|el] (aspiradora|robot) (vuelve|volver) a [la] base" ] }
        texts "pt-BR" => { done: "%{names} voltando para a base." },
              en: { description: "Sends the robot vacuum back to its dock.", done: "Sending %{names} home." },
              es: { description: "Manda el robot aspirador de vuelta a la base.", done: "%{names} vuelve a la base." }

        def self.command = "home"
      end
    end
  end
end
