# Uma chamada de IA da instalação (Lote 2): provedor, modelo, tokens, custo
# estimado e origem. Nunca guarda prompt nem resposta. Base do contador e do
# limite mensal (Ai::Budget) e da tela "Uso de IA".
class AiCall < ApplicationRecord
  acts_as_tenant :tenant

  SOURCES = { "automacao" => "Automação", "pergunta" => "Perguntar à casa", "teste" => "Teste de conexão" }.freeze
  STATUSES = { "ok" => "Ok", "error" => "Erro", "blocked" => "Bloqueada (limite)" }.freeze

  belongs_to :site, optional: true
  belongs_to :automation, optional: true

  validates :source, inclusion: { in: SOURCES.keys }
  validates :status, inclusion: { in: STATUSES.keys }

  scope :this_month, -> { where(created_at: Time.current.beginning_of_month..) }
  scope :charged, -> { where.not(status: "blocked") }

  def tokens = input_tokens + output_tokens
  def source_label = SOURCES.fetch(source, source)
  def status_label = STATUSES.fetch(status, status)
end
