module Automations
  module TriggerTypes
    # Alguém respondeu a um aviso com botões (Lote 1), pelo push, pelo aviso
    # in-app ou pela tela de notificações. Filtro opcional pelos ids dos
    # botões. No texto: {{ trigger.action }} (id do botão), {{ trigger.user }}
    # (quem respondeu) e {{ trigger.data.x }} (dados do aviso).
    class NotificationActionTrigger < Base
      describe key: "notification_action", label: "Resposta de aviso",
               fields: [ f("actions", :text, "Botões (ids separados por vírgula; vazio = qualquer)", en: "Buttons (comma-separated IDs; empty = any)", es: "Botones (IDs separados por coma; vacío = cualquiera)") ]
      texts "pt-BR" => { title: "Resposta de aviso (%{ids})", replied: "%{user} respondeu \"%{answer}\"" },
            en: { label: "Notification reply", title: "Notification reply (%{ids})", replied: "%{user} replied \"%{answer}\"" },
            es: { label: "Respuesta de aviso", title: "Respuesta de aviso (%{ids})", replied: "%{user} respondió \"%{answer}\"" }

      def self.event = "notification_action"

      def self.ids(t) = t["actions"].to_s.split(",").map(&:strip).compact_blank

      def self.fires_on_event?(t, payload) = ids(t).empty? || ids(t).include?(payload["action"])

      def self.title(t) = ids(t).any? ? text(:title, ids: ids(t).join(", ")) : label

      def self.event_info(_t, payload)
        { "type" => key, "title" => text(:replied, user: payload["user"], answer: payload["title"] || payload["action"]),
          "action" => payload["action"], "user" => payload["user"], "user_id" => payload["user_id"],
          "notification_id" => payload["notification_id"], "data" => payload["data"] }.compact
      end
    end
  end
end
