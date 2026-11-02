module Automations
  module ActionTypes
    # Publicar no MQTT (ondaA1, A7; o `mqtt.publish` do HA): tópico e
    # conteúdo (texto com Liquid), retido se pedir. Sai pelo broker do
    # servidor (MQTT_URL). Segurada em sombra (sai para fora).
    class MqttPublishAction < Base
      describe key: "mqtt_publish", label: "Publicar no MQTT",
               fields: [ f("topic", :template, "Tópico", required: true, en: "Topic", es: "Tema"),
                         f("payload", :template, "Conteúdo", en: "Payload", es: "Contenido"),
                         f("retain", :bool, "Reter no broker", en: "Retain on the broker", es: "Retener en el broker") ]
      texts "pt-BR" => { topic: "o tópico não pode ter + nem #." },
            en: { label: "Publish to MQTT", topic: "the topic cannot have + or #." },
            es: { label: "Publicar en MQTT", topic: "el tema no puede tener + ni #." }

      def self.rules(node) = node["topic"].to_s.match?(/[+#]/) && !Dsl.template?(node["topic"]) ? [ text(:topic) ] : []

      def self.call(e, _path, node)
        topic = e.ctx.render(node["topic"])
        payload = e.ctx.render(node["payload"].to_s)
        title = "MQTT #{topic}"
        return [ title, "simulated", payload.truncate(80) ] if e.dry_run?

        Mqtt::Listener.publish(topic, payload, retain: node["retain"] == true)
        [ title, "ok", payload.truncate(80) ]
      rescue Drivers::Mqtt::Error => ex
        raise Engine::Failure, ex.message
      end
    end
  end
end
