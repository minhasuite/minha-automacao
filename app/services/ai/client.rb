# Erros e utilitários comuns dos provedores de IA. A IA do MA é só a da
# própria instalação (Configurações → IA, chave da pessoa em AiAccount, pelo
# Ai::Request): não há IA paga da suíte nem plano.
module Ai
  class Client
    # A mensagem vai para a tela/app: sempre pt-BR genérico. Detalhe do
    # provedor (corpo da resposta) só no log.
    #
    # `detail`: o motivo técnico curto (status HTTP e tipo do erro, tempo
    # esgotado, corte por max_tokens), sem prompt nem resposta; vai para o
    # AiCall. `retry_after`: segundos pedidos pelo provedor (cabeçalho).
    # `usage`: tokens já gastos numa resposta que veio mas não serviu.
    class Error < StandardError
      attr_reader :detail, :retry_after, :usage

      def initialize(msg = nil, detail: nil, retry_after: nil, usage: nil)
        super(msg)
        @detail = detail
        @retry_after = retry_after
        @usage = usage
      end
    end

    # 429/5xx/overloaded/timeout/rede: vale tentar de novo (Ai::Request tenta, com espera).
    class TransientError < Error; end
    # A resposta parou no `max_tokens` (o raciocínio do modelo também conta):
    # o Ai::Request tenta de novo com o dobro do limite.
    class TruncatedError < Error; end

    # Saída estruturada (Anthropic e OpenAI strict) recusa objeto sem
    # `additionalProperties: false`: fecha todos os objetos do schema,
    # inclusive os aninhados, sem depender de cada feature lembrar.
    def self.closed(node)
      case node
      when Array then node.map { |n| closed(n) }
      when Hash
        out = node.to_h { |k, v| [ k, k.to_s.in?(%w[properties]) ? v.transform_values { |x| closed(x) } : closed(v) ] }
        object = Array(node[:type] || node["type"]).map(&:to_s).include?("object")
        object && !(node.key?(:additionalProperties) || node.key?("additionalProperties")) ? out.merge(additionalProperties: false) : out
      else node
      end
    end
  end
end
