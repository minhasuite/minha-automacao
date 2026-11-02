module Automations
  module ActionTypes
    # "Gerar dados por IA" (Lote 2): o "Pedir à IA" com o estado da casa no
    # contexto. O usuário escolhe pontos, áreas e/ou etiquetas; o sistema põe
    # antes do pedido o valor, a qualidade, há quanto tempo mudou e o resumo
    # do histórico de cada um (Ai::PointContext). Genérico: "vigia de
    # anomalia" e "resumo da semana" são automações do usuário, não código.
    class AiDataAction < AiTaskAction
      describe key: "ai_data", label: "Gerar dados por IA", defaults: { "response_variable" => "ia", "history" => "24h" },
               fields: [ f("points", :points, "Contexto: pontos", en: "Context: points", es: "Contexto: puntos"),
                         f("areas", :areas, "Contexto: áreas", en: "Context: areas", es: "Contexto: áreas"),
                         f("tags", :tags, "Contexto: etiquetas", en: "Context: tags", es: "Contexto: etiquetas"),
                         f("history", :duration, "Resumo do histórico de (ex.: 24h; vazio = só o estado agora)", en: "History summary for (e.g. 24h; empty = current state only)", es: "Resumen del historial de (ej.: 24h; vacío = solo el estado actual)") ] + FIELDS
      returns "{data (texto ou os campos), provider, model, tokens, cost}"
      texts "pt-BR" => { context: "escolha pontos, áreas ou etiquetas para o contexto." },
            en: { label: "Generate data with AI", returns: "{data (text or the fields), provider, model, tokens, cost}", context: "choose points, areas or tags for the context." },
            es: { label: "Generar datos con IA", returns: "{data (texto o los campos), provider, model, tokens, cost}", context: "elige puntos, áreas o etiquetas para el contexto." }

      def self.rules(node)
        msgs = super
        msgs << text(:context) if %w[points areas tags].all? { |k| node[k].blank? }
        msgs
      end

      def self.context(e, node)
        Ai::PointContext.text(e.ctx, point_ids: node["points"], area_ids: node["areas"], tag_ids: node["tags"], history_s: Dsl.seconds(node["history"]))
      end
    end
  end
end
