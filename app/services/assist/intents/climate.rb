module Assist
  module Intents
    # Clima (HassClimateSetTemperature, HassClimateGetTemperature): o ponto
    # de ajuste em graus do aparelho dito, e a temperatura daqui (área do
    # satélite) ou da casa (média dos sensores de temperatura expostos).
    module Climate
      def self.degrees?(point) = point.device_class == "temperature" || point.unit.to_s.match?(/°|\A[CF]\z/)

      class SetTemperature < Intent
        describe key: "climate_set_temperature", slots: %w[name area temperature], numbers: %w[temperature],
                 description: "Ajusta a temperatura alvo de um ar-condicionado, termostato ou aquecedor.",
                 sentences: { "pt-BR" => [ "(colocar|coloque|coloca|ajustar|ajuste|ajusta|deixar|deixe|deixa|mudar|mude|muda|por|ponha|ligar|ligue|liga) [a temperatura (da|do|de)] {name} (em|para|a|no|na) {temperature} [graus|grau]",
                                           "temperatura (da|do|de) {name} (em|para|a) {temperature} [graus|grau]" ],
                              "en" => [ "set [the temperature of] {name} [temperature] to {temperature} [degrees]", "{name} temperature to {temperature} [degrees]" ],
                              "es" => [ "(pon|poner|ajusta|ajustar|cambia|cambiar|deja) [la temperatura (de|del|de la)] {name} (a|en) {temperature} [grados]" ] }
        texts "pt-BR" => { done: "%{names} em %{value}.", slots: { temperature: "Temperatura alvo" } },
              en: { description: "Sets the target temperature of an air conditioner, thermostat or heater.", done: "%{names} set to %{value}.",
                    slots: { temperature: "Target temperature" } },
              es: { description: "Ajusta la temperatura objetivo de un aire acondicionado, termostato o calefactor.", done: "%{names} a %{value}.",
                    slots: { temperature: "Temperatura objetivo" } }

        def self.handle(ctx, slots)
          value = Assist.number(slots["temperature"]) or return
          points = Assist.targets(ctx, [ slots["name"], slots["area"] ].compact.join(" "), "setpoint", command: "set").select { |p| Climate.degrees?(p) }
          return if points.empty?

          shown = "#{value.to_s.sub(/\.0\z/, '')} #{points.first.unit.presence || '°'}".strip
          run(ctx, points, "set", value, done: :done, value: shown)
        end
      end

      class GetTemperature < Intent
        describe key: "climate_get_temperature", slots: %w[area],
                 description: "Diz a temperatura daqui ou de uma área (média dos sensores).",
                 sentences: { "pt-BR" => [ "(qual|como) [e|esta] a temperatura [aqui|em casa|agora|da casa|dentro de casa]", "que temperatura (faz|esta) [aqui|agora]",
                                           "(esta|ta) (quente|frio) [aqui]" ],
                              "en" => [ "what [is|s] the temperature [here|inside|at home|now]", "what s the temperature [here|inside]",
                                        "how (hot|cold|warm) is it [in here|inside]" ],
                              "es" => [ "(cual|que) es la temperatura [aqui|en casa|ahora]", "que temperatura hace [aqui|ahora]" ] }
        texts "pt-BR" => { now: "Está %{value}." },
              en: { description: "Tells the temperature here or in an area (average of the sensors).", now: "It's %{value}." },
              es: { description: "Dice la temperatura de aquí o de un área (promedio de los sensores).", now: "Hace %{value}." }

        def self.handle(ctx, slots)
          area = slots["area"].present? ? ctx.site.areas.to_a.find { |a| a.all_names.any? { |n| Assist.clean(n) == Assist.clean(slots["area"]) } } : ctx.area
          all = Assist.exposed(ctx.site.points.where(capability: "measure", quality: "good")).select { |p| Climate.degrees?(p) && p.value.is_a?(Numeric) }
          list = area ? all.select { |p| area.subtree_ids.include?(p.effective_area_id) } : []
          list = all if list.empty?
          return if list.empty?

          avg = (list.sum(&:value).to_f / list.size).round(1)
          reply(text(:now, value: "#{ActiveSupport::NumberHelper.number_to_rounded(avg, precision: 1, strip_insignificant_zeros: true, locale: I18n.locale)} #{list.first.unit}".strip),
                points: list)
        end
      end
    end
  end
end
