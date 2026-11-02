module Assist
  module Intents
    # Estado (HassGetState): "qual a temperatura da sala", "a porta está
    # aberta?", "quais luzes estão ligadas", "quantas janelas estão abertas".
    module State
      # Palavra de estado (pt, en, es) → valor booleano esperado.
      WORDS = {
        true => %w[ligado ligada ligados ligadas aceso acesa acesos acesas aberto aberta abertos abertas on open encendido encendida encendidos encendidas
                   abierto abierta abiertos abiertas prendido prendida prendidos prendidas],
        false => %w[desligado desligada desligados desligadas apagado apagada apagados apagadas fechado fechada fechados fechadas off closed shut
                    cerrado cerrada cerrados cerradas]
      }.freeze

      def self.expected(word) = WORDS.find { |_, list| list.include?(Assist.normalize(word)) }&.first

      # Valor do ponto como sim/não (liga/desliga, aberto/fechado) ou nil.
      def self.truth(point)
        v = point.value
        return v if v == true || v == false
        return v == "open" if point.capability == "gate"
        return v["state"].to_s.in?(%w[on playing paused]) if v.is_a?(Hash) && v.key?("state")

        nil
      end

      def self.line(point) = "#{point.display_names.compact.join(' ')}: #{point.quality == 'good' ? Assist.value_text(point) : Read.text(:no_signal)}"

      class Is < Intent
        describe key: "state_is", slots: %w[name state], tool: false,
                 description: "Responde sim ou não: a porta está aberta? a luz está ligada?",
                 sentences: { "pt-BR" => [ "[o|a|os|as] {name} (esta|ta|estao|ficou|ficaram) {state}" ],
                              "en" => [ "(is|are) [the] {name} {state}" ],
                              "es" => [ "(esta|estan) [el|la|los|las] {name} {state}", "[el|la|los|las] {name} (esta|estan) {state}" ] }
        texts "pt-BR" => { yes: "Sim. %{lines}.", no: "Não. %{lines}." },
              en: { description: "Answers yes or no: is the door open? is the light on?", yes: "Yes. %{lines}.", no: "No. %{lines}." },
              es: { description: "Responde sí o no: ¿la puerta está abierta? ¿la luz está encendida?", yes: "Sí. %{lines}.", no: "No. %{lines}." }

        def self.handle(ctx, slots)
          want = State.expected(slots["state"])
          return if want.nil?

          points = Assist.find_points(ctx.site, slots["name"], area: ctx.area).reject { |p| State.truth(p).nil? }.first(5)
          return if points.empty?

          reply(text(points.all? { |p| State.truth(p) == want } ? :yes : :no, lines: points.map { |p| State.line(p) }.join(". ")), points: points)
        end
      end

      class Which < Intent
        describe key: "state_which", slots: %w[name state], tool: false,
                 description: "Lista ou conta o que está num estado: quais luzes estão ligadas, quantas janelas abertas.",
                 sentences: { "pt-BR" => [ "(quais|que|quantos|quantas) [as|os] {name} (estao|esta|ficaram) {state}" ],
                              "en" => [ "(which|what|how many) {name} (is|are) {state}" ],
                              "es" => [ "(cuales|que|cuantos|cuantas) {name} (esta|estan) {state}" ] }
        texts "pt-BR" => { list: "%{names}.", none: "Nenhum.", count: "%{count}: %{names}." },
              en: { description: "Lists or counts what is in a state: which lights are on, how many windows are open.", list: "%{names}.", none: "None.",
                    count: "%{count}: %{names}." },
              es: { description: "Lista o cuenta lo que está en un estado: qué luces están encendidas, cuántas ventanas abiertas.", list: "%{names}.",
                    none: "Ninguno.", count: "%{count}: %{names}." }

        def self.handle(ctx, slots)
          want = State.expected(slots["state"])
          return if want.nil?

          all = Assist.find_points(ctx.site, slots["name"], area: ctx.area).reject { |p| State.truth(p).nil? }
          return if all.empty?

          hits = all.select { |p| State.truth(p) == want }
          return reply(text(:none), points: all) if hits.empty?

          names = Assist.list(hits.map { |p| p.display_names.compact.join(" ") })
          count = Assist.normalize(ctx.heard).match?(/\A(?:quant|how many|cuant)/)
          reply(count ? text(:count, count: hits.size, names: names) : text(:list, names: names), points: hits)
        end
      end

      class Read < Intent
        describe key: "read_state", slots: %w[name area],
                 description: "Lê o estado ou a medida de um ponto, aparelho ou área.",
                 sentences: { "pt-BR" => [ "(qual|quanto|como|quantos|quantas) [e|esta|ta|estao|marca|sao] {name}" ],
                              "en" => [ "(what|how) (is|s|are) [the] {name}", "how much is [the] {name}", "what does [the] {name} (say|read|show)" ],
                              "es" => [ "(cual|cuanto|como|cuantos|cuantas) (es|esta|estan|marca|son) [el|la|los|las] {name}", "que marca [el|la] {name}" ] }
        texts "pt-BR" => { no_signal: "sem sinal" },
              en: { description: "Reads the state or measurement of a point, device or area.", no_signal: "no signal" },
              es: { description: "Lee el estado o la medida de un punto, aparato o área.", no_signal: "sin señal" }

        def self.handle(ctx, slots)
          points = Assist.find_points(ctx.site, [ slots["name"], slots["area"] ].compact.join(" "), area: ctx.area).first(5)
          return if points.empty?

          Reply.new(text: "#{points.map { |p| State.line(p) }.join('. ')}.", intent: key, points: points)
        end
      end
    end
  end
end
