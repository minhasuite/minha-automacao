module Integrations
  # Estação do ano (catalogo): astronômica (equinócios e solstícios pelas
  # fórmulas de Meeus, erro de minutos) ou meteorológica (por mês), já
  # invertida no hemisfério sul pela latitude do local. Sem rede.
  class SeasonPlugin < SchemaPlugin
    describe key: "season", title: "Estação do ano", icon: "leaf",
             description: "A estação do ano de agora (primavera, verão, outono, inverno) no hemisfério do local, astronômica ou meteorológica, para automações."
    SEASONS = %w[spring summer autumn winter].freeze
    texts "pt-BR" => { fields: { type: "Tipo" }, options: { type: { astronomical: "Astronômica (equinócios e solstícios)", meteorological: "Meteorológica (por mês)" } },
                       points: { season: "Estação do ano" }, seasons: { spring: "Primavera", summer: "Verão", autumn: "Outono", winter: "Inverno" } },
          en: { title: "Season", description: "The current season (spring, summer, autumn, winter) in the place's hemisphere, astronomical or meteorological, for automations.",
                fields: { type: "Type" }, options: { type: { astronomical: "Astronomical (equinoxes and solstices)", meteorological: "Meteorological (by month)" } },
                points: { season: "Season" }, seasons: { spring: "Spring", summer: "Summer", autumn: "Autumn", winter: "Winter" } },
          es: { title: "Estación del año", description: "La estación de ahora (primavera, verano, otoño, invierno) en el hemisferio del lugar, astronómica o meteorológica, para automatizaciones.",
                fields: { type: "Tipo" }, options: { type: { astronomical: "Astronómica (equinoccios y solsticios)", meteorological: "Meteorológica (por mes)" } },
                points: { season: "Estación del año" }, seasons: { spring: "Primavera", summer: "Verano", autumn: "Otoño", winter: "Invierno" } }
    field :type, :select, options: %w[astronomical meteorological], default: "astronomical"

    # Meeus, cap. 27: JDE médio de março, junho, setembro e dezembro (Y em milênios desde 2000).
    TERMS = [
      [ 2_451_623.80984, 365_242.37404, 0.05169, -0.00411, -0.00057 ], [ 2_451_716.56767, 365_241.62603, 0.00325, 0.00888, -0.00030 ],
      [ 2_451_810.21715, 365_242.01767, -0.11575, 0.00337, 0.00078 ], [ 2_451_900.05952, 365_242.74049, -0.06223, -0.00823, 0.00032 ]
    ].freeze

    class << self
      # Começo das 4 estações (norte: primavera, verão, outono, inverno) no ano.
      def starts(year)
        y = (year - 2000) / 1000.0
        TERMS.map { |c| Time.zone.at((c.each_with_index.sum { |k, i| k * (y**i) } - 2_440_587.5) * 86_400) }
      end

      # → chave da estação no hemisfério (norte por padrão).
      def season(at, south: false, type: "astronomical")
        i = if type == "meteorological" then [ 3, 3, 0, 0, 0, 1, 1, 1, 2, 2, 2, 3 ][at.month - 1]
        else
              starts(at.year).rindex { |t| t <= at } || 3 # antes do equinócio de março: inverno
        end
        SEASONS[south ? (i + 2) % 4 : i]
      end

      def label(key) = text("seasons.#{key}")

      def entries(integration)
        [ entry(id: "season:#{integration.id}", name: integration.name, manufacturer: nil, poll_s: 3600,
                points: [ point("season", "enum", options: SEASONS.map { |k| label(k) }, writable: false, icon: "leaf") ]) ]
      end

      def read(device, at = Time.current)
        key = season(at, south: device.site.latitude.to_f.negative?, type: conf(device.integration, :type))
        opts = Array(device.points.first&.options)
        { "season" => opts[SEASONS.index(key)] || label(key) }
      end
    end
  end
end
