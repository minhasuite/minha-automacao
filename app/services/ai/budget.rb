module Ai
  # Limite mensal da IA da instalação (Configurações → IA): gasto estimado em
  # US$ e/ou número de chamadas, contados em AiCall no mês corrente. Passou =
  # bloqueia a próxima chamada e avisa os administradores uma vez por mês.
  # A configuração fica em `tenants.settings["ai"]` (`default_provider`,
  # `limit_usd`, `limit_calls`; vazio = sem limite).
  class Budget
    def self.for(tenant) = new(tenant)

    def initialize(tenant)
      @tenant = tenant
      @cfg = tenant.settings.to_h["ai"] || {}
    end

    def default_provider = @cfg["default_provider"]
    def limit_usd = @cfg["limit_usd"]&.to_f
    def limit_calls = @cfg["limit_calls"]&.to_i
    def cost = AiCall.this_month.charged.sum(:cost).to_f
    def calls = AiCall.this_month.charged.count

    def exceeded?
      (limit_usd && cost >= limit_usd) || (limit_calls && calls >= limit_calls) || false
    end

    # Fração usada do limite mais apertado (0..1; nil sem limite), para a barra.
    def ratio
      parts = [ (cost / limit_usd if limit_usd&.positive?), (calls.to_f / limit_calls if limit_calls&.positive?) ].compact
      parts.empty? ? nil : parts.max.clamp(0, 1)
    end

    def check!
      return unless exceeded?

      Notifier.notify!(kind: "sistema", title: "Limite mensal da IA atingido",
                       body: "As chamadas de IA ficam bloqueadas até o mês que vem ou até você aumentar o limite em Configurações → IA.",
                       data: { "url" => "/configuracoes/ia" }, dedup_key: "ai-limit:#{@tenant.id}:#{Time.current.strftime('%Y-%m')}")
      raise Ai::Request::LimitReached, "Limite mensal da IA atingido. Aumente em Configurações → IA."
    end

    def self.save!(tenant, form)
      num = ->(v) { Float(v.to_s.tr(",", "."), exception: false)&.then { |n| n.positive? ? n : nil } }
      ai = { "default_provider" => form[:default_provider].presence_in(Ai.providers.map(&:key)),
             "limit_usd" => num.(form[:limit_usd]), "limit_calls" => num.(form[:limit_calls])&.to_i }.compact
      tenant.update!(settings: tenant.settings.to_h.merge("ai" => ai))
    end
  end
end
