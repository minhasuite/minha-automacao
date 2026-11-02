module Automations
  module TriggerTypes
    # Pessoa entrou ou saiu de uma zona (Pacote 3; o `zone` do HA). O ponto é
    # a pessoa (helper Pessoa, valor = nome da zona) e `zone` o helper Zona.
    class ZoneTrigger < Base
      describe key: "zone", label: "Pessoa entrou ou saiu de zona", defaults: { "event" => "enter" },
               fields: [ f("point", :point, "Pessoa", required: true, en: "Person", es: "Persona"), f("zone", :point, "Zona", required: true, en: "Zone", es: "Zona"),
                         f("event", :select, "Quando", required: true, options: -> { events }, en: "When", es: "Cuándo") ]
      texts "pt-BR" => { events: { enter: "Entrou", leave: "Saiu" }, title: { enter: "Entrou da zona", leave: "Saiu da zona" } },
            en: { label: "Person entered or left a zone", events: { enter: "Entered", leave: "Left" }, title: { enter: "Entered the zone", leave: "Left the zone" } },
            es: { label: "Persona entró o salió de una zona", events: { enter: "Entró", leave: "Salió" }, title: { enter: "Entró en la zona", leave: "Salió de la zona" } }

      def self.events = %w[enter leave].index_with { |k| text("events.#{k}") }

      def self.fires_on_change?(t, value, was)
        name = Point.find_by(id: t["zone"])&.name or return false
        t["event"] == "leave" ? was == name && value != name : value == name && was != name
      end

      def self.title(t) = t["event"].in?(%w[enter leave]) ? text("title.#{t['event']}") : ""
    end
  end
end
