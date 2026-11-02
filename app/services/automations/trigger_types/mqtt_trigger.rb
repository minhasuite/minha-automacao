module Automations
  module TriggerTypes
    # MQTT (ondaA1, A5; o gatilho `mqtt` do HA): mensagem num tópico (com os
    # curingas + e #) e, se pedir, com o conteúdo exato. O Mqtt::Listener
    # assina os tópicos das automações ligadas (`topics`) e entrega cada
    # mensagem a `receive`. No texto: {{ trigger.topic }}, {{ trigger.payload }}
    # e, se for JSON, {{ trigger.data.campo }}.
    class MqttTrigger < Base
      TOPIC = /\A\S{1,200}\z/

      describe key: "mqtt", label: "Mensagem MQTT",
               fields: [ f("topic", :text, "Tópico (curingas + e #)", required: true, en: "Topic (wildcards + and #)", es: "Tema (comodines + y #)"),
                         f("payload", :text, "Só com este conteúdo (opcional)", en: "Only with this payload (optional)", es: "Solo con este contenido (opcional)") ]
      texts "pt-BR" => { topic: "tópico inválido (sem espaço; # só no fim)." },
            en: { label: "MQTT message", topic: "invalid topic (no spaces; # only at the end)." },
            es: { label: "Mensaje MQTT", topic: "tema inválido (sin espacios; # solo al final)." }

      def self.event = "mqtt_message"

      def self.rules(node)
        t = node["topic"].to_s
        t.match?(TOPIC) && !t.delete_suffix("#").include?("#") ? [] : [ text(:topic) ]
      end

      def self.matches?(filter, topic)
        f = filter.split("/")
        parts = topic.split("/")
        f.each_with_index do |seg, i|
          return true if seg == "#"
          return false if parts[i].nil? || (seg != "+" && seg != parts[i])
        end
        f.size == parts.size
      end

      def self.fires_on_event?(t, payload) = matches?(t["topic"].to_s, payload["topic"].to_s) && (t["payload"].blank? || t["payload"] == payload["payload"])
      def self.title(t) = "MQTT #{t['topic']}"
      def self.event_info(t, payload) = { "type" => key, "title" => title(t), "topic" => payload["topic"], "payload" => payload["payload"], "data" => payload["data"] }.compact

      def self.scope = Automation.where(enabled: true).where("definition->'triggers' @> ?", [ { type: key } ].to_json)

      # Tópicos das automações ligadas (todas as instalações: o broker é do servidor).
      def self.topics
        ActsAsTenant.without_tenant { scope.pluck(:definition) }.flat_map { |d| Array(d["triggers"]).filter_map { |t| t["topic"] if t["type"] == key } }.uniq
      end

      # Mensagem do broker → evento "mqtt_message" em cada local com gatilho que casa.
      def self.receive(topic, payload)
        list = ActsAsTenant.without_tenant { scope.includes(:tenant).to_a }
        list = list.select { |a| a.definition["triggers"].any? { |t| t["type"] == key && matches?(t["topic"].to_s, topic) } }
        return if list.empty?

        data = begin
          JSON.parse(payload.to_s)
        rescue JSON::ParserError
          nil
        end
        list.uniq(&:site_id).each do |a|
          ActsAsTenant.with_tenant(a.tenant) do
            Triggers.event(a.site_id, event, { "topic" => topic, "payload" => payload.to_s.first(10_000), "data" => (data if data.is_a?(Hash)) }.compact)
          end
        end
      end
    end
  end
end
