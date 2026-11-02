# Uma execução de automação (ESQUEMA-V1 §4.5): o gatilho, o trace passo a
# passo (`steps`: condições com os valores avaliados, cada ação com resultado
# e tempo) e, enquanto espera, o estado para retomar (`state`). `dry_run` =
# simulação. Guardada por RETENTION_DAYS e no máximo KEEP por automação.
class AutomationRun < ApplicationRecord
  acts_as_tenant :tenant

  STATUSES = LocalizedLabel.for("automations.labels.run_statuses", %w[queued running waiting done skipped stopped failed cancelled loop])
  TONES = { "done" => "success", "failed" => "danger", "loop" => "warn", "cancelled" => "warn", "waiting" => "info",
            "running" => "info", "queued" => "info" }.freeze
  RETENTION_DAYS = 30
  KEEP = 200
  # Rodando sem atualizar há esse tempo = morreu junto com o processo; não
  # segura mais o modo single/fila.
  STALE = 2.minutes

  belongs_to :automation
  belongs_to :site
  belongs_to :cause_run, class_name: "AutomationRun", optional: true

  validates :status, inclusion: { in: STATUSES.keys }

  scope :recent, -> { order(created_at: :desc) }
  scope :real, -> { where(dry_run: false) }
  scope :active, -> { real.where(status: "waiting").or(real.where(status: "running", updated_at: STALE.ago..)) }

  def status_label = STATUSES.fetch(status, status)
  def tone = TONES.fetch(status, "muted")
  def finished? = finished_at.present?
  def duration_s = finished_at && (finished_at - started_at)
  # Resposta do script (Lote 1): as variáveis no fim da execução.
  def response = state["vars"].to_h.except("repeat_index", "secret")

  def cancel!
    update!(status: "cancelled", finished_at: Time.current, resume_at: nil,
            steps: steps + [ { "at" => Time.current.iso8601(3), "kind" => "cancel", "title" => "Cancelada: disparou de novo (modo reiniciar)", "result" => "skipped" } ])
  end

  # Retenção (ReadingsMaintenanceJob, todo dia).
  def self.prune!(now = Time.current)
    ActsAsTenant.without_tenant do
      where(created_at: ...(now - RETENTION_DAYS.days)).delete_all
      Automation.find_each do |a|
        cut = where(automation_id: a.id).order(created_at: :desc).offset(KEEP).pick(:created_at)
        where(automation_id: a.id, created_at: ..cut).delete_all if cut
      end
    end
  end
end
