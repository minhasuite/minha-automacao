module Automations
  module ActionTypes
    # "Anotar" (Lote 7; `logbook.log` e `system_log.write` do HA): um texto
    # Liquid que fica só no trace da execução. Não sai nada: roda em sombra.
    class TraceNoteAction < Base
      def self.shadow_safe?(_e, _node) = true

      describe key: "trace_note", label: "Anotar no histórico da execução", fields: [ f("message", :template, "Texto", required: true, en: "Text", es: "Texto") ]
      texts en: { label: "Add a note to the run history" }, es: { label: "Anotar en el historial de la ejecución" }

      def self.call(e, _path, node)
        [ "Anotar", "ok", e.ctx.render(node["message"], limit: 500) ]
      end
    end
  end
end
