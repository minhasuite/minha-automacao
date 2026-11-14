# Motivo técnico da falha da IA (status HTTP e tipo do erro, tempo esgotado,
# corte por max_tokens, JSON inválido) e quantas tentativas a chamada levou.
# Nunca o prompt nem a resposta.
class AddDetailToAiCalls < ActiveRecord::Migration[8.1]
  def change
    add_column :ai_calls, :detail, :string
    add_column :ai_calls, :attempts, :integer, default: 1, null: false
  end
end
