module Automations
  module TriggerTypes
    # Tag lida (appweb D4, a "tag" do HA): o app do celular leu uma tag NFC ou
    # um QR com `minhaautomacao://tag/<id>` e mandou `POST /mobile_devices/:id/tag`.
    # Filtro opcional pelo id. No texto: {{ trigger.tag }}, {{ trigger.user }},
    # {{ trigger.device }} (o celular que leu).
    class TagTrigger < Base
      describe key: "tag", label: "Tag lida (NFC ou QR)",
               fields: [ f("tag", :text, "Id da tag (vazio = qualquer)", en: "Tag ID (empty = any)", es: "ID de la etiqueta (vacío = cualquiera)") ]
      texts "pt-BR" => { title: "Tag lida (%{tag})", scanned: "%{user} leu a tag %{tag}" },
            en: { label: "Tag scanned (NFC or QR)", title: "Tag scanned (%{tag})", scanned: "%{user} scanned tag %{tag}" },
            es: { label: "Etiqueta leída (NFC o QR)", title: "Etiqueta leída (%{tag})", scanned: "%{user} leyó la etiqueta %{tag}" }

      EVENT = "tag_scanned".freeze
      def self.event = EVENT
      def self.fires_on_event?(t, payload) = t["tag"].blank? || t["tag"].to_s.strip == payload["tag"].to_s
      def self.title(t) = t["tag"].present? ? text(:title, tag: t["tag"]) : label

      def self.event_info(_t, payload)
        { "type" => key, "title" => text(:scanned, user: payload["user"], tag: payload["tag"]), "tag" => payload["tag"],
          "user" => payload["user"], "user_id" => payload["user_id"], "device" => payload["device"] }.compact
      end
    end
  end
end
