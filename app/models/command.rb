# Comando rastreável (ESQUEMA-V1 §4.4, G8): quem pediu, de onde, para qual
# ponto e o que aconteceu. pending → sent → confirmed | failed | expired.
class Command < ApplicationRecord
  acts_as_tenant :tenant

  STATUSES = { "pending" => "Pendente", "sent" => "Enviado", "confirmed" => "Confirmado",
               "failed" => "Falhou", "expired" => "Expirado" }.freeze
  SOURCES = { "web" => "web", "api" => "app/API", "automation" => "automação", "alexa" => "Alexa" }.freeze
  # Comando que não saiu nesse tempo não sai mais (portão abrindo 5 min depois).
  TTL = 1.minute
  RETENTION_DAYS = 365

  belongs_to :site
  belongs_to :point
  belongs_to :user, optional: true

  validates :status, inclusion: { in: STATUSES.keys }
  validates :source, inclusion: { in: SOURCES.keys }

  scope :recent, -> { order(created_at: :desc) }

  def status_label = STATUSES.fetch(status, status)
  def source_label = SOURCES.fetch(source, source)
end
