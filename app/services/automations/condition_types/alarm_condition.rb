module Automations
  module ConditionTypes
    # Alarme está (Pacote 3): o painel de alarme num estado; "armado" vale
    # qualquer modo armado.
    class AlarmCondition < Base
      ARMED = "armed".freeze

      describe key: "alarm", label: "Alarme está", defaults: { "is" => ARMED },
               fields: [ f("point", :point, "Painel de alarme", required: true, en: "Alarm panel", es: "Panel de alarma"),
                         f("is", :select, "Está", required: true, options: -> { { ARMED => text(:armed_any) }.merge(HelperTypes::AlarmPanel.states) }, en: "Is", es: "Está") ]
      texts "pt-BR" => { armed_any: "Armado (qualquer modo)" },
            en: { label: "Alarm is", armed_any: "Armed (any mode)" }, es: { label: "La alarma está", armed_any: "Armada (cualquier modo)" }

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
