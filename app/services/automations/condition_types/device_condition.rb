module Automations
  module ConditionTypes
    # Aparelho está (ondaA1, A6; a condição `device` do HA): "a porta está
    # aberta", "a luz está ligada", em palavras (DeviceAutomations).
    class DeviceCondition < Base
      describe key: "device", label: "Aparelho está",
               fields: [ f("point", :point, "Aparelho e ponto", required: true, en: "Device and point", es: "Aparato y punto"),
                         f("state", :device_condition, "Está", required: true, en: "Is", es: "Está") ]
      texts en: { label: "Device is" }, es: { label: "El aparato está" }

      def self.check(ev, c)
        p = ev.point!(c["point"])
        v = ev.ctx.value(p)
        [ DeviceAutomations.holds?(p, c["state"].to_s, v), "#{p.device&.name}: #{DeviceAutomations.conditions_for(p)[c['state']] || c['state']}", ev.label(p, v) ]
      end
    end
  end
end
