module Automations
  module ActionTypes
    # Espera alguém responder a um aviso desta execução (botões do "Avisar"),
    # durável como as outras esperas. A resposta ({action, title, user,
    # user_id, data}) vai para a variável; no tempo limite ela fica vazia.
    class WaitNotificationAction < Base
      def self.shadow_safe?(_e, _node) = true

      describe key: "wait_notification", label: "Esperar resposta do aviso", defaults: { "timeout" => "10m", "response_variable" => "resposta" },
               fields: [ f("actions", :text, "Só os botões (ids separados por vírgula; vazio = qualquer)", en: "Only these buttons (comma-separated IDs; empty = any)", es: "Solo los botones (IDs separados por coma; vacío = cualquiera)"),
                         f("timeout", :duration, "Tempo limite", required: true, en: "Timeout", es: "Tiempo límite"),
                         f("continue_on_timeout", :bool, "Seguir se o tempo acabar", en: "Continue if time runs out", es: "Seguir si se acaba el tiempo") ]
      returns "{action, title, user, user_id, notification_id, data} (vazio no tempo limite)"
      texts en: { label: "Wait for notification reply", returns: "{action, title, user, user_id, notification_id, data} (empty on timeout)" },
            es: { label: "Esperar respuesta del aviso", returns: "{action, title, user, user_id, notification_id, data} (vacío al agotarse el tiempo)" }

      def self.control? = true

      def self.call(e, path, node)
        timeout = Dsl.seconds(node["timeout"]).to_i
        label = "Esperar resposta do aviso (até #{Dsl.duration_label(timeout)})"
        if e.dry_run?
          e.ctx.vars[node["response_variable"]] = nil
          return [ label, "simulated", "Na simulação ninguém responde: seguiria pelo tempo limite." ]
        end

        ids = node["actions"].to_s.split(",").map(&:strip).compact_blank
        e.trace(path, key, label, "waiting")
        e.suspend(Time.current + timeout, "kind" => "event", "event" => "notification_action", "match" => { "run_id" => e.run.id, "action" => ids.presence }.compact,
                                          "path" => path, "var" => node["response_variable"], "got" => "Resposta recebida", "detail" => "title",
                                          "stop_on_timeout" => node["continue_on_timeout"] == false)
        [ :halt ]
      end
    end
  end
end
