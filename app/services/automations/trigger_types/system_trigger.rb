module Automations
  module TriggerTypes
    # Sistema (ondaA1, A5; o `homeassistant: start/shutdown` do HA): o
    # servidor subiu ou vai desligar, como gatilho próprio no editor (antes
    # só pelo gatilho Evento com "system_started").
    class SystemTrigger < Base
      EVENTS = { "start" => "system_started", "shutdown" => "system_stopping" }.freeze

      describe key: "system", label: "Sistema iniciou ou vai desligar", defaults: { "event" => "start" },
               fields: [ f("event", :select, "Quando", required: true, options: -> { { "start" => SystemTrigger.text(:start), "shutdown" => SystemTrigger.text(:shutdown) } }, en: "When", es: "Cuándo") ]
      texts "pt-BR" => { start: "Iniciou", shutdown: "Vai desligar" },
            en: { label: "System started or shutting down", start: "Started", shutdown: "Shutting down" },
            es: { label: "El sistema inició o se apagará", start: "Inició", shutdown: "Se apagará" }

      def self.listens?(name) = EVENTS.value?(name)
      def self.fires_on_event?(t, payload) = EVENTS[t["event"]] == payload["event"]
      def self.title(t) = "#{label}: #{text(t['event'] == 'shutdown' ? :shutdown : :start).downcase}"
    end
  end
end
