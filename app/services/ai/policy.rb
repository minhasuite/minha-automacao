module Ai
  # Por casa + feature: está liberada no plano? Qual tier? Quanto resta da
  # cota mensal e do teto diário?
  class Policy
    def self.for(tenant, feature) = new(tenant, feature)

    attr_reader :feature

    def initialize(tenant, feature)
      @tenant = tenant
      @feature = feature.to_s
      @rule = AiPlanFeature.rule_for(feature: @feature, plan: tenant.effective_plan)
    end

    def available? = !@rule.nil? && Ai::Client.enabled?(tier)
    def tier = @rule ? @rule[:tier] : :light
    def limit = @rule && @rule[:limit]
    def used = AiUsage.count_for(@feature)
    def daily_cap = Ai::DailyCap.for(@tenant)

    def remaining
      return nil if limit.nil?

      [ limit - used, 0 ].max
    end

    def allowed?
      return false unless available?
      return false if daily_cap.exceeded?

      limit.nil? || used < limit
    end

    def check! = (raise QuotaExceeded.new(@feature, @tenant.effective_plan) unless allowed?)

    # Debita uma ação (uma vez por chamada que aconteceu de fato).
    def record!(response = nil)
      AiUsage.record!(@feature, input_tokens: response&.input_tokens, output_tokens: response&.output_tokens,
                                model: response&.model)
      daily_cap.record!
    end

    def as_json(*)
      { available: available?, limit: limit, used: used, remaining: remaining }
    end
  end
end
