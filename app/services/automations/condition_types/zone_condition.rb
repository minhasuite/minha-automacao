module Automations
  module ConditionTypes
    # Alguém na zona (Pacote 3): "alguém em casa" ou "ninguém em casa" pela
    # contagem do helper Zona.
    class ZoneCondition < Base
      describe key: "zone", label: "Alguém na zona", defaults: { "state" => "someone" },
               fields: [ f("point", :point, "Zona", required: true, en: "Zone", es: "Zona"),
                         f("state", :select, "Situação", required: true, options: -> { states }, en: "Status", es: "Situación") ]
      texts "pt-BR" => { states: { someone: "Alguém está", nobody: "Ninguém está" } },
            en: { label: "Someone in the zone", states: { someone: "Someone is there", nobody: "No one is there" } },
            es: { label: "Alguien en la zona", states: { someone: "Hay alguien", nobody: "No hay nadie" } }

      def self.states = %w[someone nobody].index_with { |k| text("states.#{k}") }

      def self.check(ev, c)
        p = ev.point!(c["point"])
        n = ev.ctx.value(p).to_i
        [ c["state"] == "nobody" ? n.zero? : n.positive?, "#{states.fetch(c['state'], '')} em #{p.name}", "agora: #{n} pessoa(s)" ]
      end
    end
  end
end
