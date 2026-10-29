module Ai
  # Feature indisponível no plano ou cota (mensal ou diária) esgotada.
  # A API responde 402 plan_required.
  class QuotaExceeded < StandardError
    attr_reader :feature, :plan

    def initialize(feature, plan = nil)
      @feature = feature
      @plan = plan.to_s
      super("IA indisponível ou cota excedida para \"#{feature}\"")
    end

    # Grátis não tem IA: o recado é o plano, não a cota.
    def not_in_plan? = @plan == Plans::DEFAULT
    def user_message = not_in_plan? ? "Disponível no Pro." : "Seu plano não inclui mais usos de IA este mês."
  end
end
