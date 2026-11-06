module Dashboards
  module Widgets
    # Perguntar à casa no painel (o campo "Pergunte à IA" do HA): a pergunta vai para Ai::Ask (o mesmo da
    # tela /perguntar: estado dos pontos como contexto, só leitura) e a resposta aparece no próprio card.
    # Web: `POST /perguntar/painel` (frame do widget); app: `POST /api/v1/sites/:id/ask`.
    class AskWidget < Base
      describe type: "ask", label: "Perguntar à casa", icon: "sparkles", params: %w[placeholder]
      texts en: { label: "Ask the house" }, es: { label: "Preguntar a la casa" }

      # `ready`: há provedor de IA ligado (sem ele, o card leva a Configurações → IA).
      def self.data(_r, _w, _binds) = [ { "ready" => AiAccount.pick.present? }, [] ]
    end
  end
end
