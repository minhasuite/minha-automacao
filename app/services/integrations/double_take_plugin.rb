module Integrations
  # Double Take (+ CompreFace, apps do catálogo): rosto reconhecido nas
  # câmeras do Frigate. O Double Take publica cada reconhecimento no MQTT da
  # casa (`<tópico>/matches/<nome>`); o descobridor ::DoubleTake do
  # Mqtt::Listener lê e:
  # - liga o ponto "Rosto: <nome>" (volta a desligado `hold_s` depois do
  #   último reconhecimento), que o rastreador People::Trackers::Face usa
  #   como presença da pessoa (visto = em casa; não visto = sem opinião);
  # - grava o ponto de evento "Rosto reconhecido" e dispara o evento
  #   `face_recognized` (gatilho "Evento") com nome, câmera e confiança.
  # Um aparelho por pessoa (nome igual ao do Double Take).
  class DoubleTakePlugin < SchemaPlugin
    describe key: "double_take", title: "Double Take (rostos)", icon: "user-circle",
             description: "Rosto reconhecido nas câmeras (Double Take com CompreFace e Frigate) vira presença da pessoa e evento para automações."
    texts "pt-BR" => { fields: { topic: "Tópico MQTT", names: "Pessoas (uma por linha, como no Double Take)", hold_s: "Vista por (segundos)" },
                       hints: { topic: "double-take", names: "herlon\nmaria", hold_s: "300" },
                       points: { seen: "Rosto visto", camera: "Câmera", last: "Rosto reconhecido" }, person: "Rosto: %{name}", device: "Double Take",
                       no_names: "Informe ao menos uma pessoa.", no_broker: "Este servidor não tem MQTT (MQTT_URL): o Double Take fala por ele." },
          en: { title: "Double Take (faces)", description: "A face recognized on the cameras (Double Take with CompreFace and Frigate) becomes the person's presence and an event for automations.",
                fields: { topic: "MQTT topic", names: "People (one per line, as in Double Take)", hold_s: "Seen for (seconds)" },
                hints: { topic: "double-take", names: "herlon\nmaria", hold_s: "300" },
                points: { seen: "Face seen", camera: "Camera", last: "Face recognized" }, person: "Face: %{name}", device: "Double Take",
                no_names: "Enter at least one person.", no_broker: "This server has no MQTT (MQTT_URL): Double Take talks through it." },
          es: { title: "Double Take (rostros)", description: "Un rostro reconocido en las cámaras (Double Take con CompreFace y Frigate) se vuelve presencia de la persona y evento para automatizaciones.",
                fields: { topic: "Tema MQTT", names: "Personas (una por línea, como en Double Take)", hold_s: "Vista durante (segundos)" },
                hints: { topic: "double-take", names: "herlon\nmaria", hold_s: "300" },
                points: { seen: "Rostro visto", camera: "Cámara", last: "Rostro reconocido" }, person: "Rostro: %{name}", device: "Double Take",
                no_names: "Indica al menos una persona.", no_broker: "Este servidor no tiene MQTT (MQTT_URL): Double Take se comunica por él." }
    field :topic, default: "double-take"
    field :names, :textarea, required: true
    field :hold_s, :number, default: 300

    class << self
      def names(integration) = conf(integration, :names).to_s.split(/[\n,;]+/).map(&:squish).compact_blank.uniq.first(50)
      def slug(name) = name.to_s.downcase.squish
      def hold(integration) = conf(integration, :hold_s).to_i.clamp(30, 3600)

      def entries(integration)
        list = names(integration).presence or raise(Integrations::Error, text(:no_names))
        prefix = conf(integration, :topic).to_s.delete_suffix("/")
        list.map do |n|
          entry(id: "double_take:#{prefix}:#{slug(n)}", name: text(:person, name: n.capitalize), manufacturer: "Double Take", poll_s: 0,
                address: { "topic" => prefix, "name" => slug(n) },
                points: [ point("seen", "motion", device_class: "occupancy", address: { "name" => slug(n), "hold_s" => hold(integration), "tracker" => "face" }),
                          point("camera", "text"), point("last", "event") ])
        end
      end

      # Sem leitura: tudo chega pelo MQTT.
      def read(_device) = {}
    end
  end
end
