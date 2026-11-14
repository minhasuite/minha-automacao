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
    # Teto da resposta. Os modelos atuais pensam por padrão (Haiku/Sonnet 5.5) e o raciocínio conta
    # no max_tokens: com 1000 a saída estruturada do "Vigia" saía cortada todo dia ("formato
    # inesperado"). Só se paga o que o modelo usa; cortou mesmo assim, tenta uma vez com o dobro.
    MAX_TOKENS = 16_000
    MAX_TOKENS_CAP = 32_000
    # Nova tentativa só no que é passageiro (429, 5xx/529 overloaded, tempo esgotado, rede), com
    # espera crescente (ou o retry-after do provedor, até RETRY_AFTER_MAX). Em segundo plano
    # (automação, montar painel) vale esperar mais; com alguém olhando a tela, uma retentativa curta.
    BACKGROUND = %w[automacao painel].freeze
    BACKOFF = { background: [ 2, 8 ], interactive: [ 1 ] }.freeze
    TIMEOUT = { background: 90, interactive: 60 }.freeze
    RETRY_AFTER_MAX = 30
    # Espera entre tentativas (trocável no spec).
    class_attribute :sleeper, default: ->(seconds) { sleep(seconds) }

    def self.call(**) = new(**).call

    def initialize(tenant:, prompt:, source:, system: nil, images: [], schema: nil, provider: nil, model: nil, temperature: nil,
                   max_tokens: nil, timeout: nil, site: nil, automation: nil)
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
      @mode = BACKGROUND.include?(source.to_s) ? :background : :interactive
      @timeout = timeout || TIMEOUT.fetch(@mode)
      @site = site
      @automation = automation
    end

    def call
      Shadow.block!("IA (#{@source})")
      budget = Ai::Budget.for(@tenant)
      account = AiAccount.pick(@provider, default: budget.default_provider) or raise Ai::Client::Error, missing
      plugin = account.plugin
      model = @model.presence || account.model_or_default
      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @attempts = 0
      @reasons = []
      @spent = { input: 0, output: 0 }
      begin
        budget.check!
        check_capabilities!(plugin)
        res = attempt(account, plugin, model)
      rescue Ai::Client::Error => e
        add_spent(e.usage)
        @reasons << e.detail if e.detail.present?
        log!(plugin.key, model, e.is_a?(LimitReached) ? "blocked" : "error", error: e.message, **spent(model))
        raise
      end
      add_spent(res.usage)
      log!(plugin.key, model, "ok", **spent(model))
      Response.new(data: res.data, provider: plugin.key, model: model, input_tokens: @spent[:input], output_tokens: @spent[:output],
                   cost: ModelPrice.cost_for(model, @spent[:input], @spent[:output]))
    end

    private

    # Chama o provedor, tentando de novo no que é passageiro e, cortada no max_tokens, com o dobro.
    def attempt(account, plugin, model)
      max_tokens = @max_tokens
      waits = BACKOFF.fetch(@mode).dup
      grown = false
      loop do
        @attempts += 1
        begin
          return account.client.complete(model: model, system: @system, user: content, schema: (Ai::Client.closed(@schema) if @schema),
                                         max_tokens: max_tokens, timeout: @timeout,
                                         temperature: (@temperature if plugin.supports?(:temperature)))
        rescue Ai::Client::TruncatedError => e
          raise if grown || max_tokens >= MAX_TOKENS_CAP

          add_spent(e.usage)
          @reasons << e.detail
          max_tokens = [ max_tokens * 2, MAX_TOKENS_CAP ].min
          grown = true
        rescue Ai::Client::TransientError => e
          raise if waits.empty?

          @reasons << e.detail if e.detail.present?
          wait = waits.shift
          wait = [ e.retry_after, RETRY_AFTER_MAX ].min if e.retry_after.to_f.positive?
          Rails.logger.info("[ai] #{plugin.key} #{e.detail || e.class.name.demodulize}: nova tentativa em #{wait}s")
          self.class.sleeper.call(wait + rand * 0.5)
        end
      end
    end

    def add_spent(usage)
      return if usage.blank?

      @spent[:input] += usage[:input].to_i
      @spent[:output] += usage[:output].to_i
    end

    def spent(model) = { input: @spent[:input], output: @spent[:output], cost: ModelPrice.cost_for(model, @spent[:input], @spent[:output]) }

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

    # Um AiCall por pedido (não por tentativa): tokens somados, tentativas e o motivo técnico de cada falha.
    def log!(provider, model, status, input: 0, output: 0, cost: 0, error: nil)
      AiCall.create!(source: @source, site: @site, automation: @automation, provider: provider, model: model, status: status,
                     input_tokens: input, output_tokens: output, cost: cost, error: error&.truncate(200),
                     attempts: [ @attempts.to_i, 1 ].max, detail: Array(@reasons).uniq.join(" · ").truncate(250).presence,
                     duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started) * 1000).round)
    end
  end
end
