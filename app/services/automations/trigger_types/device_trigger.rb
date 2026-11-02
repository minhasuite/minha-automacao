module Automations
  module TriggerTypes
    # Aparelho (ondaA1, A6; o gatilho `device` do HA): o ponto do aparelho e
    # o que ele fez em palavras (DeviceAutomations), com "por pelo menos".
    class DeviceTrigger < Base
      describe key: "device", label: "Aparelho fez algo",
               fields: [ f("point", :point, "Aparelho e ponto", required: true, en: "Device and point", es: "Aparato y punto"),
                         f("event", :device_trigger, "Quando", required: true, en: "When", es: "Cuándo"),
                         f("for", :duration, "Por pelo menos", en: "For at least", es: "Durante al menos") ]
      texts en: { label: "Device did something" }, es: { label: "El aparato hizo algo" }

      def self.point_for(t) = Point.find_by(id: t["point"])
      def self.fires_on_change?(t, value, was) = (p = point_for(t)) ? DeviceAutomations.fires?(p, t["event"].to_s, value, was) : false
      def self.holds?(t, value) = t["for"].blank? || fires_on_change?(t, value, nil)

      def self.title(t)
        p = point_for(t)
        "#{p&.device&.name || label}: #{DeviceAutomations.triggers_for(p)[t['event']] || t['event']}"
      end
    end
  end
end
