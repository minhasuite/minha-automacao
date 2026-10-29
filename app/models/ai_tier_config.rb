# Tier → provedor/modelo/effort, editável no painel admin. Global. Sem linha
# na tabela, vale o default do código (config/initializers/ai.rb).
class AiTierConfig < ApplicationRecord
  TIERS = %w[light standard deep].freeze
  EFFORTS = %w[low medium high].freeze
  CACHE_KEY = "ai_tier_configs/map".freeze

  validates :tier, presence: true, uniqueness: true, inclusion: { in: TIERS }
  validates :provider, presence: true, inclusion: { in: ->(_) { Ai::Provider.names } }
  validates :model, presence: true
  validates :effort, inclusion: { in: EFFORTS }, allow_blank: true

  after_commit { Rails.cache.delete(CACHE_KEY) }

  def self.map
    Rails.cache.fetch(CACHE_KEY) do
      code_defaults.merge(all.to_h { |c| [ c.tier, { provider: c.provider, model: c.model, effort: c.effort.presence } ] })
    end
  end

  def self.for(tier)
    map.fetch(tier.to_s) { raise Ai::Client::Error, "tier de IA desconhecido: #{tier.inspect}" }
  end

  def self.code_defaults
    Rails.application.config.x.ai.tiers.to_h.to_h do |tier, cfg|
      [ tier.to_s, { provider: cfg[:provider] || Ai::Provider::DEFAULT, model: cfg[:model], effort: cfg[:effort] } ]
    end
  end

  # Idempotente: find-or-create, nunca sobrescreve o que o admin editou.
  def self.seed_defaults!
    code_defaults.each do |tier, cfg|
      find_or_create_by!(tier: tier) { |r| r.assign_attributes(provider: cfg[:provider], model: cfg[:model], effort: cfg[:effort]) }
    end
  end
end
