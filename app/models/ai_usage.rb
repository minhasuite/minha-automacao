# Uso de IA por empresa/mês/feature. A cota é por CONTAGEM; tokens ficam para
# custo. Zerar a empresa NÃO zera isto (senão "zerar" viraria reset de cota).
class AiUsage < ApplicationRecord
  acts_as_tenant :tenant

  def self.period_for(date = Date.current) = date.beginning_of_month

  def self.count_for(feature, date: Date.current)
    where(feature: feature.to_s, period: period_for(date)).sum(:count)
  end

  def self.record!(feature, input_tokens: 0, output_tokens: 0, model: nil)
    row = find_or_create_by!(feature: feature.to_s, period: period_for)
    where(id: row.id).update_all([ # rubocop:disable Rails/SkipsModelValidations
      "count = count + 1, input_tokens = input_tokens + ?, output_tokens = output_tokens + ?, " \
      "model = COALESCE(?, model), updated_at = now()",
      input_tokens.to_i, output_tokens.to_i, model.presence
    ])
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def estimated_cost = ModelPrice.cost_for(model, input_tokens, output_tokens)
end
