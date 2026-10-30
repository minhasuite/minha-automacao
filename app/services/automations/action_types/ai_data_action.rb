module Automations
  module ActionTypes
    # "Gerar dados por IA" (Lote 2): o "Pedir à IA" com o estado da casa no
    # contexto. O usuário escolhe pontos, áreas e/ou etiquetas; o sistema põe
    # antes do pedido o valor, a qualidade, há quanto tempo mudou e o resumo
    # do histórico de cada um (Ai::PointContext). Genérico: "vigia de
    # anomalia" e "resumo da semana" são automações do usuário, não código.
    class AiDataAction < AiTaskAction
      describe key: "ai_data", label: "Gerar dados por IA", defaults: { "response_variable" => "ia", "history" => "24h" },
               fields: [ f("points", :points, "Contexto: pontos"), f("areas", :areas, "Contexto: áreas"), f("tags", :tags, "Contexto: etiquetas"),
                         f("history", :duration, "Resumo do histórico de (ex.: 24h; vazio = só o estado agora)") ] + FIELDS
      returns "{data (texto ou os campos), provider, model, tokens, cost}"

      def self.rules(node)
        msgs = super
        msgs << "escolha pontos, áreas ou etiquetas para o contexto." if %w[points areas tags].all? { |k| node[k].blank? }
        msgs
      end

      def self.context(e, node)
        Ai::PointContext.text(e.ctx, point_ids: node["points"], area_ids: node["areas"], tag_ids: node["tags"], history_s: Dsl.seconds(node["history"]))
      end
    end
  end
end
