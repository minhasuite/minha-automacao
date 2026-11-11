# Comando rastreável (ESQUEMA-V1 §4.4, G8): quem pediu, de onde, para qual
# ponto e o que aconteceu. pending → sent → confirmed | failed | expired;
# `skipped` = automação não mandou para aparelho sem sinal (docs/confiabilidade.md).
# Falha passageira volta a `pending` e tenta de novo (`attempts`, Transient).
# Lote (`batch_id`): um anúncio em várias Echo da mesma conta; o líder
# (batch_id = id) executa e os outros acompanham o status dele.
class Command < ApplicationRecord
  acts_as_tenant :tenant

  STATUSES = LocalizedLabel.for("labels.command_statuses", %w[pending sent confirmed failed expired skipped])
  SOURCES = LocalizedLabel.for("labels.command_sources", %w[web api automation alexa voice push bridge google guest])
  # Comando que não saiu nesse tempo não sai mais (portão abrindo 5 min depois).
  TTL = 1.minute
  RETENTION_DAYS = 365

  belongs_to :site
  belongs_to :point
  belongs_to :user, optional: true

  validates :status, inclusion: { in: STATUSES.keys }
  validates :source, inclusion: { in: SOURCES.keys }

  scope :recent, -> { order(created_at: :desc) }

  # Os outros comandos do lote que este (líder) executa.
  def followers = batch_id == id ? ::Command.where(batch_id: id).where.not(id: id) : ::Command.none

  def status_label = STATUSES.fetch(status, status)
  def source_label = SOURCES.fetch(source, source)
end
