# Acontecimento num local ou ponto (ESQUEMA-V1 §4.4). Hoje: `quality` (o
# ponto ficou indisponível, com erro ou voltou). Os drivers (F3) somam
# movimento, botão, fim de limpeza. `scene`: cena acionada (o Diário mostra).
class Event < ApplicationRecord
  acts_as_tenant :tenant

  KINDS = %w[quality scene].freeze
  RETENTION_DAYS = 365

  belongs_to :site
  belongs_to :point, optional: true

  validates :kind, inclusion: { in: KINDS }

  scope :recent, -> { order(at: :desc) }
end
