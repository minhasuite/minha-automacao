module Integrations
  # Lua (catalogo): fase da lua e quanto dela está iluminado, calculados aqui
  # (mês sinódico a partir de uma lua nova conhecida), sem rede.
  class MoonPlugin < SchemaPlugin
    describe key: "moon", title: "Lua", icon: "moon",
             description: "Fase da lua (nova, crescente, cheia, minguante…) e a parte iluminada, para automações e painéis. Calculada aqui, sem internet."
    PHASES = %w[new_moon waxing_crescent first_quarter waxing_gibbous full_moon waning_gibbous last_quarter waning_crescent].freeze
    texts "pt-BR" => { points: { phase: "Fase da lua", illumination: "Lua iluminada" },
                       phases: { new_moon: "Lua nova", waxing_crescent: "Crescente", first_quarter: "Quarto crescente", waxing_gibbous: "Crescente gibosa",
                                 full_moon: "Lua cheia", waning_gibbous: "Minguante gibosa", last_quarter: "Quarto minguante", waning_crescent: "Minguante" } },
          en: { title: "Moon", description: "Moon phase (new, waxing, full, waning…) and how much of it is lit, for automations and dashboards. Calculated here, no internet.",
                points: { phase: "Moon phase", illumination: "Moon illumination" },
                phases: { new_moon: "New moon", waxing_crescent: "Waxing crescent", first_quarter: "First quarter", waxing_gibbous: "Waxing gibbous",
                          full_moon: "Full moon", waning_gibbous: "Waning gibbous", last_quarter: "Last quarter", waning_crescent: "Waning crescent" } },
          es: { title: "Luna", description: "Fase de la luna (nueva, creciente, llena, menguante…) y cuánto está iluminada, para automatizaciones y paneles. Calculada aquí, sin internet.",
                points: { phase: "Fase de la luna", illumination: "Luna iluminada" },
                phases: { new_moon: "Luna nueva", waxing_crescent: "Creciente", first_quarter: "Cuarto creciente", waxing_gibbous: "Gibosa creciente",
                          full_moon: "Luna llena", waning_gibbous: "Gibosa menguante", last_quarter: "Cuarto menguante", waning_crescent: "Menguante" } }

    SYNODIC = 29.530588853
    NEW_MOON = Time.utc(2000, 1, 6, 18, 14).freeze

    class << self
      # → [chave da fase, idade em dias, iluminação %]
      def phase(at = Time.current)
        age = ((at.to_f - NEW_MOON.to_f) / 86_400) % SYNODIC
        f = age / SYNODIC * 28 # a escala de 0 a 28 do HA (astral)
        key = if f < 0.5 || f >= 27.5 then "new_moon"
        elsif f < 6.5 then "waxing_crescent"
        elsif f < 7.5 then "first_quarter"
        elsif f < 13.5 then "waxing_gibbous"
        elsif f < 14.5 then "full_moon"
        elsif f < 20.5 then "waning_gibbous"
        elsif f < 21.5 then "last_quarter"
        else "waning_crescent"
        end
        [ key, age, ((1 - Math.cos(2 * Math::PI * age / SYNODIC)) / 2 * 100).round ]
      end

      def label(key) = text("phases.#{key}")

      def entries(integration)
        [ entry(id: "moon:#{integration.id}", name: integration.name, manufacturer: nil, poll_s: 3600,
                points: [ point("phase", "enum", options: PHASES.map { |k| label(k) }, writable: false, icon: "moon"),
                          point("illumination", unit: "%", icon: "moon") ]) ]
      end

      # A opção na língua em que o ponto nasceu (mesma posição de PHASES).
      def read(device, at = Time.current)
        key, _, lit = phase(at)
        opts = Array(device.points.find { |p| p.address["field"] == "phase" }&.options)
        { "phase" => opts[PHASES.index(key)] || label(key), "illumination" => lit }
      end
    end
  end
end
