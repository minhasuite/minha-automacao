module Automations
  module TriggerTypes
    # Pessoa entrou ou saiu de uma zona (Pacote 3; o `zone` do HA). O ponto é
    # a pessoa (helper Pessoa, valor = nome da zona) e `zone` o helper Zona.
    class ZoneTrigger < Base
      EVENTS = { "enter" => "Entrou", "leave" => "Saiu" }.freeze

      describe key: "zone", label: "Pessoa entrou ou saiu de zona", defaults: { "event" => "enter" },
               fields: [ f("point", :point, "Pessoa", required: true), f("zone", :point, "Zona", required: true),
                         f("event", :select, "Quando", required: true, options: EVENTS) ]

      def self.fires_on_change?(t, value, was)
        name = Point.find_by(id: t["zone"])&.name or return false
        t["event"] == "leave" ? was == name && value != name : value == name && was != name
      end

      def self.title(t) = "#{EVENTS.fetch(t['event'], '')} da zona"
    end
  end
end
