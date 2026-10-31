module Automations
  module ConditionTypes
    # Alguém na zona (Pacote 3): "alguém em casa" ou "ninguém em casa" pela
    # contagem do helper Zona.
    class ZoneCondition < Base
      STATES = { "someone" => "Alguém está", "nobody" => "Ninguém está" }.freeze

      describe key: "zone", label: "Alguém na zona", defaults: { "state" => "someone" },
               fields: [ f("point", :point, "Zona", required: true), f("state", :select, "Situação", required: true, options: STATES) ]

      def self.check(ev, c)
        p = ev.point!(c["point"])
        n = ev.ctx.value(p).to_i
        [ c["state"] == "nobody" ? n.zero? : n.positive?, "#{STATES.fetch(c['state'], '')} em #{p.name}", "agora: #{n} pessoa(s)" ]
      end
    end
  end
end
