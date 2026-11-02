module Automations
  module TriggerTypes
    # Presença na zona (Pacote 3): o primeiro chegou (ninguém → alguém) ou
    # todos saíram (alguém → ninguém). O ponto é o helper Zona (valor = quantas
    # pessoas estão nela).
    class PresenceTrigger < Base
      describe key: "presence", label: "Presença na zona", defaults: { "event" => "all_left" },
               fields: [ f("point", :point, "Zona", required: true, en: "Zone", es: "Zona"),
                         f("event", :select, "Quando", required: true, options: -> { events }, en: "When", es: "Cuándo") ]
      texts "pt-BR" => { events: { first_arrived: "O primeiro chegou", all_left: "Todos saíram" } },
            en: { label: "Presence in zone", events: { first_arrived: "First person arrived", all_left: "Everyone left" } },
            es: { label: "Presencia en la zona", events: { first_arrived: "Llegó el primero", all_left: "Todos se fueron" } }

      def self.events = %w[first_arrived all_left].index_with { |k| text("events.#{k}") }

      def self.fires_on_change?(t, value, was)
        now = value.to_i
        before = was.to_i
        t["event"] == "first_arrived" ? before.zero? && now.positive? : before.positive? && now.zero?
      end

      def self.title(t) = events.fetch(t["event"], label)
    end
  end
end
