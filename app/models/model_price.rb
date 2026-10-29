# Preço de modelo em USD por milhão de tokens (custo estimado no admin).
# Defaults plausíveis, não cotação — confira no fornecedor.
class ModelPrice < ApplicationRecord
  CACHE_KEY = "model_prices/map".freeze

  DEFAULTS = {
    "anthropic" => { "claude-haiku-5-5" => [ 0.1, 0.5 ], "claude-sonnet-5-5" => [ 2.0, 10.0 ], "claude-haiku-4-5" => [ 1.0, 5.0 ], "claude-sonnet-5" => [ 3.0, 15.0 ], "claude-opus-4-8" => [ 15.0, 75.0 ] },
    # Gemini API, plano pago, prompt até 200k (ai.google.dev/gemini-api/docs/pricing, 07/10/2026).
    "gemini" => { "gemini-3.5-flash-lite" => [ 0.30, 2.50 ], "gemini-3.5-flash" => [ 1.50, 9.00 ],
                  "gemini-3.1-pro-preview" => [ 2.00, 12.00 ], "gemini-2.5-flash-lite" => [ 0.10, 0.40 ],
                  "gemini-2.5-flash" => [ 0.30, 2.50 ], "gemini-2.5-pro" => [ 1.25, 10.00 ] },
    "openai" => { "gpt-5" => [ 1.25, 10.0 ], "gpt-5-mini" => [ 0.25, 2.0 ] }
  }.freeze

  validates :provider, :model, presence: true
  validates :model, uniqueness: { scope: :provider }
  validates :input_per_mtok, :output_per_mtok, numericality: { greater_than_or_equal_to: 0 }

  after_commit { Rails.cache.delete(CACHE_KEY) }

  def self.map = Rails.cache.fetch(CACHE_KEY) { all.to_h { |p| [ p.model, [ p.input_per_mtok.to_f, p.output_per_mtok.to_f ] ] } }

  def self.cost_for(model, input_tokens, output_tokens)
    input, output = map[model.to_s]
    return 0.0 unless input

    (input_tokens.to_i * input + output_tokens.to_i * output) / 1_000_000.0
  end

  def self.seed_defaults!
    DEFAULTS.each do |provider, models|
      models.each do |model, (input, output)|
        find_or_create_by!(provider: provider, model: model) { |r| r.assign_attributes(input_per_mtok: input, output_per_mtok: output) }
      end
    end
  end
end
