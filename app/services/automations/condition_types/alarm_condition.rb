module Automations
  module ConditionTypes
    # Alarme está (Pacote 3): o painel de alarme num estado; "armado" vale
    # qualquer modo armado.
    class AlarmCondition < Base
      ARMED = "armed".freeze

      describe key: "alarm", label: "Alarme está", defaults: { "is" => ARMED },
               fields: [ f("point", :point, "Painel de alarme", required: true),
                         f("is", :select, "Está", required: true, options: -> { { ARMED => "Armado (qualquer modo)" }.merge(HelperTypes::AlarmPanel.states) }) ]

      def self.check(ev, c)
        p = ev.point!(c["point"])
        v = ev.ctx.value(p).to_s
        ok = c["is"] == ARMED ? HelperTypes::AlarmPanel.armed?(v) : v == c["is"]
        states = HelperTypes::AlarmPanel.states
        [ ok, "#{p.name} #{(c['is'] == ARMED ? 'armado' : states.fetch(c['is'], c['is'])).downcase}", "agora: #{states.fetch(v, v).downcase}" ]
      end
    end
  end
end
