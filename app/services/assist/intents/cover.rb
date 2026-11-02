module Assist
  module Intents
    # Cortina, persiana, janela, portão (HassOpenCover, HassCloseCover,
    # HassSetPosition): ponto de posição (setpoint em %) com classe de
    # cobertura, ou o `gate` (pulso). Portão é crítico: por voz, recusa.
    module Cover
      CLASSES = %w[awning blind curtain damper door garage gate shade shutter window].freeze

      def self.cover?(point) = point.capability == "gate" || (point.capability == "setpoint" && point.device_class.in?(CLASSES))
      def self.find(ctx, slots) = Assist.targets(ctx, [ slots["name"], slots["area"] ].compact.join(" "), %w[setpoint gate]).select { |p| cover?(p) && p.writable }

      class Base < Intent
        def self.open = true

        def self.handle(ctx, slots)
          points = Cover.find(ctx, slots)
          return if points.empty?

          gates, levels = points.partition { |p| p.capability == "gate" }
          gates = gates.select { |p| (p.value == "open") != open } # pulso só no que precisa mudar
          replies = [ (run(ctx, levels, "set", open ? 100 : 0, done: :done) if levels.any?), (run(ctx, gates, "pulse", done: :done) if gates.any?) ].compact
          replies.empty? ? reply(text(:done, names: Assist.list(points.map(&:name))), points: points) : reply(replies.map(&:text).join(" "), points: points)
        end
      end

      class Open < Base
        describe key: "cover_open", slots: %w[name area],
                 description: "Abre cortina, persiana, janela ou toldo.",
                 sentences: { "pt-BR" => [ "(abrir|abra|abre|levantar|levante|levanta|subir|suba|sobe) {name}" ],
                              "en" => [ "(open|raise) {name}" ],
                              "es" => [ "(abrir|abre|abra|subir|sube|levanta|levantar) {name}" ] }
        texts "pt-BR" => { done: "Abri %{names}." },
              en: { description: "Opens a curtain, blind, window or awning.", done: "Opened %{names}." },
              es: { description: "Abre cortina, persiana, ventana o toldo.", done: "Abrí %{names}." }
      end

      class Close < Base
        describe key: "cover_close", slots: %w[name area],
                 description: "Fecha cortina, persiana, janela ou toldo.",
                 sentences: { "pt-BR" => [ "(fechar|feche|fecha|baixar|baixe|baixa|descer|desca|desce) {name}" ],
                              "en" => [ "(close|lower|shut) {name}" ],
                              "es" => [ "(cerrar|cierra|cierre|bajar|baja) {name}" ] }
        texts "pt-BR" => { done: "Fechei %{names}." },
              en: { description: "Closes a curtain, blind, window or awning.", done: "Closed %{names}." },
              es: { description: "Cierra cortina, persiana, ventana o toldo.", done: "Cerré %{names}." }

        def self.open = false
      end

      class Position < Intent
        describe key: "cover_position", slots: %w[name area position], numbers: %w[position],
                 description: "Deixa cortina ou persiana numa posição (0 fechada, 100 aberta).",
                 sentences: { "pt-BR" => [ "(abrir|abra|abre|colocar|coloque|coloca|deixar|deixe|deixa|ajustar|ajuste|ajusta) {name} (em|para|a) {position} [%|por cento]" ],
                              "en" => [ "(open|set|move) {name} to {position} [%|percent]" ],
                              "es" => [ "(abre|abrir|pon|poner|ajusta|ajustar|deja) {name} (a|al|en) {position} [%|por ciento]" ] }
        texts "pt-BR" => { done: "%{names} em %{value}%.", slots: { position: "Posição de 0 (fechada) a 100 (aberta)" } },
              en: { description: "Moves a curtain or blind to a position (0 closed, 100 open).", done: "%{names} set to %{value}%.",
                    slots: { position: "Position from 0 (closed) to 100 (open)" } },
              es: { description: "Deja cortina o persiana en una posición (0 cerrada, 100 abierta).", done: "%{names} al %{value}%.",
                    slots: { position: "Posición de 0 (cerrada) a 100 (abierta)" } }

        def self.handle(ctx, slots)
          value = Assist.number(slots["position"])&.round&.clamp(0, 100) or return
          points = Cover.find(ctx, slots).select { |p| p.capability == "setpoint" }
          run(ctx, points, "set", value, done: :done, value: value)
        end
      end
    end
  end
end
