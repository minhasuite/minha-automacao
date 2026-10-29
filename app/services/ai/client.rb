# Cliente único de IA. Recebe um tier, resolve provedor + modelo em
# AiTierConfig e delega ao adaptador. Prompt entra, JSON sai, mais o uso
# (tokens) para a cota e o custo.
#
#   Ai::Client.new(tier: :standard).complete(system:, user:, schema:, timeout: 30)
module Ai
  class Client
    Response = Data.define(:data, :model, :usage) do
      def input_tokens = usage[:input].to_i
      def output_tokens = usage[:output].to_i
    end

    # A mensagem vai para o app: sempre pt-BR genérico. Detalhe do provedor
    # (corpo da resposta) só no log.
    class Error < StandardError; end
    # 429/5xx/timeout/rede: vale tentar outro modelo.
    class TransientError < Error; end

    DEFAULT_MAX_TOKENS = 4_000
    TIMEOUT = 60

    # Interruptor antes da credencial: desligar a IA no admin vale mesmo com
    # chave configurada (botão de pânico de custo).
    # Sem tier: liga se algum tier tem a chave do seu provedor. Com tier: a
    # chave do provedor daquele tier.
    def self.enabled?(tier = nil)
      return false unless FeatureFlag.on?("ai")

      tiers = tier ? [ AiTierConfig.for(tier) ] : AiTierConfig.map.values
      tiers.any? { |cfg| Ai::Provider.configured?(cfg[:provider].presence || Ai::Provider::DEFAULT) }
    end

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

    def initialize(tier:)
      @tier = tier
    end

    # `user` é String ou lista de blocos no formato Anthropic (texto + imagem
    # base64); o adaptador OpenAI traduz.
    #
    # Falha passageira (modelo sobrecarregado, cota do minuto) num tier acima
    # do light tenta uma vez o modelo do light, que é o mais disponível.
    def complete(system:, user:, schema:, max_tokens: DEFAULT_MAX_TOKENS, timeout: TIMEOUT, thinking: false)
      raise Error, "A IA não está disponível agora." unless FeatureFlag.on?("ai")

      args = { system: system, user: user, schema: self.class.closed(schema), max_tokens: max_tokens, timeout: timeout }
      cfg = AiTierConfig.for(@tier)
      begin
        call(cfg, thinking ? cfg[:effort] : nil, **args)
      rescue TransientError => e
        light = AiTierConfig.for(:light)
        raise e if light[:model] == cfg[:model] || !Ai::Provider.configured?(light[:provider])

        Rails.logger.warn("[ai] #{cfg[:model]} falhou (#{e.message}) — tentando #{light[:model]}")
        call(light, nil, **args)
      end
    end

    private

    def call(cfg, effort, **args)
      name = cfg[:provider].presence || Ai::Provider::DEFAULT
      raise Error, "A IA não está disponível agora." unless Ai::Provider.configured?(name)

      result = Ai::Provider.for(name).complete(model: cfg.fetch(:model), effort: effort, **args)
      # O adaptador devolve chaves símbolo; quem lê com string ("text") recebia nil e caía no texto sem IA.
      data = result.data.is_a?(Hash) ? result.data.with_indifferent_access : result.data
      Response.new(data: data, model: cfg[:model], usage: result.usage)
    end
  end
end
