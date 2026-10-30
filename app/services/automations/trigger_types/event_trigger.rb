module Automations
  module TriggerTypes
    # Evento (Lote 4, G6; o gatilho `event` do HA): qualquer evento interno
    # pelo nome, os da ação "Disparar evento" e os do sistema
    # (`Triggers::SYSTEM_EVENTS`, ex.: "automation_finished"), com filtro
    # opcional nos dados (campo: valor, todos precisam bater). No texto:
    # {{ trigger.event }} e {{ trigger.data.campo }}.
    class EventTrigger < Base
      describe key: "event", label: "Evento",
               fields: [ f("event", :text, "Nome do evento", required: true), f("match", :kv, "Só quando os dados tiverem (campo: valor)") ]

      def self.listens?(_name) = true

      def self.rules(node) = node["event"].is_a?(String) && node["event"].match?(Triggers::EVENT_NAME) ? [] : [ "nome do evento: letras minúsculas, números, _ . : e - (até 60)." ]

      def self.fires_on_event?(t, payload)
        t["event"] == payload["event"] && t["match"].to_h.all? { |k, v| payload[k].to_s == v.to_s }
      end

      def self.title(t) = "Evento #{Triggers::SYSTEM_EVENTS.fetch(t['event'], t['event'])}"

      def self.event_info(t, payload)
        { "type" => key, "title" => title(t), "event" => payload["event"], "data" => payload["data"] }
      end
    end
  end
end
