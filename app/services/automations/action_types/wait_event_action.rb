module Automations
  module ActionTypes
    # "Esperar evento" (Lote 4, G6; `wait_for_trigger` de evento do HA):
    # durável como as outras esperas. Os dados do evento vão para a variável;
    # no tempo limite ela fica vazia.
    class WaitEventAction < Base
      def self.shadow_safe?(_e, _node) = true

      describe key: "wait_event", label: "Esperar evento", defaults: { "timeout" => "10m", "response_variable" => "evento" },
               fields: [ f("event", :text, "Nome do evento", required: true), f("match", :kv, "Só quando os dados tiverem (campo: valor)"),
                         f("timeout", :duration, "Tempo limite", required: true), f("continue_on_timeout", :bool, "Seguir se o tempo acabar") ]
      returns "os dados do evento (vazio no tempo limite)"

      def self.control? = true

      def self.rules(node) = node["event"].is_a?(String) && node["event"].match?(Triggers::EVENT_NAME) ? [] : [ "nome do evento: letras minúsculas, números, _ . : e - (até 60)." ]

      def self.call(e, path, node)
        timeout = Dsl.seconds(node["timeout"]).to_i
        label = "Esperar evento #{node['event']} (até #{Dsl.duration_label(timeout)})"
        if e.dry_run?
          e.ctx.vars[node["response_variable"]] = nil if node["response_variable"].present?
          return [ label, "simulated", "Na simulação o evento não chega: seguiria pelo tempo limite." ]
        end

        e.trace(path, key, label, "waiting")
        e.suspend(Time.current + timeout, "kind" => "event", "event" => node["event"], "match" => node["match"].to_h,
                                          "path" => path, "var" => node["response_variable"], "key" => "data", "got" => "Evento #{node['event']}",
                                          "stop_on_timeout" => node["continue_on_timeout"] == false)
        [ :halt ]
      end
    end
  end
end
