module Automations
  module TriggerTypes
    # Presença na zona (Pacote 3): o primeiro chegou (ninguém → alguém) ou
    # todos saíram (alguém → ninguém). O ponto é o helper Zona (valor = quantas
    # pessoas estão nela).
    class PresenceTrigger < Base
      EVENTS = { "first_arrived" => "O primeiro chegou", "all_left" => "Todos saíram" }.freeze

      describe key: "presence", label: "Presença na zona", defaults: { "event" => "all_left" },
               fields: [ f("point", :point, "Zona", required: true), f("event", :select, "Quando", required: true, options: EVENTS) ]

      def self.fires_on_change?(t, value, was)
        now = value.to_i
        before = was.to_i
        t["event"] == "first_arrived" ? before.zero? && now.positive? : before.positive? && now.zero?
      end

      def self.title(t) = EVENTS.fetch(t["event"], label)
    end
  end
end
