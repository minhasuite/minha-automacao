module Ai
  # Uma chamada à IA da INSTALAÇÃO (chave do usuário, Configurações → IA): a
  # ação "Pedir à IA", o "Perguntar à casa" e o teste de conexão passam aqui.
  # Escolhe a conta (provedor pedido, o padrão ou o primeiro configurado),
  # confere o limite do mês, checa a capacidade do plugin (imagem, saída
  # estruturada, temperatura), chama e registra o AiCall (modelo, tokens,
  # custo, origem; nunca o prompt nem a resposta).
  #
  #   Ai::Request.call(tenant:, prompt:, source: "automacao", images: [{media_type:, data:}],
  #                    schema: {...} | nil, provider: nil, model: nil, site:, automation:)
  class Request
    class LimitReached < Ai::Client::Error; end

    Response = Data.define(:data, :provider, :model, :input_tokens, :output_tokens, :cost) do
      def tokens = input_tokens + output_tokens
      def to_h = { "data" => data.is_a?(Hash) ? data.deep_stringify_keys : data, "provider" => provider, "model" => model,
                   "tokens" => tokens, "cost" => cost.round(6) }
    end

    SYSTEM = "Você é o assistente de automação de uma casa. Responda em português do Brasil, curto e direto.".freeze
    MAX_TOKENS = 1_000

    def self.call(**) = new(**).call

    def initialize(tenant:, prompt:, source:, system: nil, images: [], schema: nil, provider: nil, model: nil, temperature: nil,
                   max_tokens: nil, timeout: 60, site: nil, automation: nil)
      @tenant = tenant
      @prompt = prompt.to_s
      @source = source
      @system = system.presence || SYSTEM
      @images = Array(images)
      @schema = schema
      @provider = provider
      @model = model
      @temperature = temperature
      @max_tokens = (max_tokens || MAX_TOKENS).to_i
      @timeout = timeout
      @site = site
      @automation = automation
    end

    def call
      budget = Ai::Budget.for(@tenant)
      account = AiAccount.pick(@provider, default: budget.default_provider) or raise Ai::Client::Error, missing
      plugin = account.plugin
      model = @model.presence || account.model_or_default
      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        budget.check!
        check_capabilities!(plugin)
        res = account.client.complete(model: model, system: @system, user: content, schema: (Ai::Client.closed(@schema) if @schema),
                                      max_tokens: @max_tokens, timeout: @timeout,
                                      temperature: (@temperature if plugin.supports?(:temperature)))
      rescue Ai::Client::Error => e
        log!(plugin.key, model, e.is_a?(LimitReached) ? "blocked" : "error", error: e.message)
        raise
      end
      input, output = res.usage.values_at(:input, :output).map(&:to_i)
      cost = ModelPrice.cost_for(model, input, output)
      log!(plugin.key, model, "ok", input: input, output: output, cost: cost)
      Response.new(data: res.data, provider: plugin.key, model: model, input_tokens: input, output_tokens: output, cost: cost)
    end

    private

    def missing = @provider.present? ? "O provedor de IA \"#{Ai.provider(@provider)&.label || @provider}\" não está configurado. Veja Configurações → IA." : "Nenhum provedor de IA configurado. Cole a chave em Configurações → IA."

    def check_capabilities!(plugin)
      raise Ai::Client::Error, "#{plugin.label} não aceita imagem." if @images.any? && !plugin.supports?(:image)
      raise Ai::Client::Error, "#{plugin.label} não tem saída estruturada." if @schema && !plugin.supports?(:structured)
    end

    # Imagens primeiro, depois o texto (blocos no formato Anthropic; o plugin traduz).
    def content
      return @prompt if @images.empty?

      @images.map { |i| { type: "image", source: { type: "base64", media_type: i[:media_type], data: i[:data] } } } + [ { type: "text", text: @prompt } ]
    end

    def log!(provider, model, status, input: 0, output: 0, cost: 0, error: nil)
      AiCall.create!(source: @source, site: @site, automation: @automation, provider: provider, model: model, status: status,
                     input_tokens: input, output_tokens: output, cost: cost, error: error&.truncate(200),
                     duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started) * 1000).round)
    end
  end
end
