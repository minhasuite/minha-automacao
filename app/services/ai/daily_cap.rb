module Ai
  # Teto DIÁRIO de chamadas de IA por empresa, somando as features. A cota
  # mensal não protege de um script madrugada adentro; isto protege. Vive no
  # Rails.cache (Solid Cache em produção): é vazão, não contabilidade.
  class DailyCap
    LIMITS = { "free" => 0, "pro" => 80, "max" => 240 }.freeze
    FALLBACK = 0

    def self.for(tenant) = new(tenant)

    def initialize(tenant)
      @tenant = tenant
    end

    def limit = LIMITS.fetch(@tenant.effective_plan.to_s, FALLBACK)
    def used = Rails.cache.read(key).to_i
    def remaining = [ limit - used, 0 ].max
    def exceeded? = used >= limit

    def record!
      Rails.cache.write(key, used + 1, expires_in: 2.days)
    end

    private

    def key = "ai_daily_cap:#{@tenant.id}:#{Time.current.in_time_zone(@tenant.timezone).to_date.iso8601}"
  end
end
