module Assist
  module Intents
    # Lâmpada (HassLightSet): brilho (absoluto ou mais/menos) e cor. O nome
    # pode ser o da lâmpada, do aparelho ou da área: o ponto de brilho ou de
    # cor é o irmão do mesmo aparelho.
    module Light
      UP = %w[aumentar aumente aumenta clarear clareie clareia increase raise brighten aumentar aumenta sube subir].freeze
      DOWN = %w[diminuir diminua diminui abaixar abaixe abaixa escurecer escureca decrease lower dim reduce disminuir disminuye baja bajar].freeze
      STEP = 25

      class Brightness < Intent
        VERBS_PT = "(ajustar|ajuste|ajusta|colocar|coloque|coloca|deixar|deixe|deixa|mudar|mude|muda|por|ponha|poe|ligar|ligue|liga|acender|acenda|acende)"
        describe key: "light_brightness", slots: %w[name area brightness], numbers: %w[brightness],
                 description: "Muda o brilho de uma lâmpada ou da área (0 a 100%). Sem número, \"mais\" ou \"menos\" sobe ou desce um quarto.",
                 sentences: { "pt-BR" => [ "#{VERBS_PT} [o brilho (da|do|de)] {name} (em|para|a|no|na) {brightness} [%|por cento]",
                                           "brilho (da|do|de) {name} (em|para|a) {brightness} [%|por cento]",
                                           "{direction} [o brilho (da|do|de)] {name}" ],
                              "en" => [ "(set|turn|put|dim|change) [the brightness of] {name} [brightness] to {brightness} [%|percent]",
                                        "{name} brightness to {brightness} [%|percent]", "{direction} [the brightness of] {name}" ],
                              "es" => [ "(pon|poner|ajusta|ajustar|cambia|cambiar|deja|dejar) [el brillo (de|del|de la)] {name} (a|al|en) {brightness} [%|por ciento]",
                                        "{direction} [el brillo (de|del|de la)] {name}" ] }
        texts "pt-BR" => { done: "Brilho de %{names} em %{value}%.", slots: { brightness: "Brilho de 0 a 100" } },
              en: { description: "Sets the brightness of a light or area (0 to 100%). Without a number, \"up\" or \"down\" moves it by a quarter.",
                    done: "Set %{names} brightness to %{value}%.", slots: { brightness: "Brightness from 0 to 100" } },
              es: { description: "Cambia el brillo de una lámpara o del área (0 a 100%). Sin número, \"sube\" o \"baja\" lo mueve un cuarto.",
                    done: "Brillo de %{names} al %{value}%.", slots: { brightness: "Brillo de 0 a 100" } }

        def self.accepts?(_ctx, slots) = slots["direction"].nil? || Assist.normalize(slots["direction"]).in?(UP + DOWN)

        def self.handle(ctx, slots)
          dir = Assist.normalize(slots["direction"]) if slots["direction"]
          return if dir && !dir.in?(UP + DOWN)

          points = Assist.targets(ctx, [ slots["name"], slots["area"] ].compact.join(" "), "dimmer", command: "set")
          return if points.empty?

          # ponytail: o passo parte do brilho do primeiro ponto; por ponto se pedirem.
          value = dir ? points.first.value.to_i + (dir.in?(UP) ? STEP : -STEP) : Assist.number(slots["brightness"])
          return if value.nil?

          value = value.round.clamp(0, 100)
          run(ctx, points, "set", value, done: :done, label: device_label, value: value)
        end
      end

      class Color < Intent
        # Nome da cor (três idiomas) → valor do ponto `color` (Points::Color).
        COLORS = {
          %w[vermelho vermelha red rojo roja] => "#ff0000", %w[verde green] => "#00ff00", %w[azul blue] => "#0000ff",
          %w[amarelo amarela yellow amarillo amarilla] => "#ffff00", %w[laranja orange naranja] => "#ff8000",
          %w[roxo roxa purple morado morada violeta violet lilas] => "#8000ff", %w[rosa pink] => "#ff69b4", %w[ciano cyan cian] => "#00ffff",
          [ "branco quente", "warm white", "blanco calido", "amarelado" ] => { "kelvin" => 2700 },
          [ "branco frio", "cool white", "cold white", "blanco frio" ] => { "kelvin" => 6500 },
          %w[branco branca white blanco blanca] => { "kelvin" => 4000 }
        }.freeze

        describe key: "light_color", slots: %w[name area color],
                 description: "Muda a cor de uma lâmpada (vermelho, azul, branco quente...).",
                 sentences: { "pt-BR" => [ "(mudar|mude|muda|trocar|troque|troca|deixar|deixe|deixa|colocar|coloque|coloca|por|ponha) [a cor (da|do|de)] {name} (de|para|em) {color}" ],
                              "en" => [ "(set|change|make|turn) [the color of] {name} [to] {color}" ],
                              "es" => [ "(cambiar|cambia|cambie|pon|poner|deja) [el color (de|del|de la)] {name} (a|en|de) {color}" ] }
        texts "pt-BR" => { done: "%{names} em %{color}.", slots: { color: "Nome da cor" } },
              en: { description: "Changes the color of a light (red, blue, warm white...).", done: "%{names} set to %{color}.", slots: { color: "Color name" } },
              es: { description: "Cambia el color de una lámpara (rojo, azul, blanco cálido...).", done: "%{names} en %{color}.", slots: { color: "Nombre del color" } }

        def self.color(name)
          want = Assist.clean(name)
          COLORS.find { |names, _| names.include?(want) }&.last
        end

        def self.handle(ctx, slots)
          value = color(slots["color"]) or return
          points = Assist.targets(ctx, [ slots["name"], slots["area"] ].compact.join(" "), "color", command: "set")
          run(ctx, points, "set", value, done: :done, label: device_label, color: slots["color"])
        end
      end
    end
  end
end
