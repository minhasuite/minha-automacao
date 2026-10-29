# Execução de automação com o trace (`steps`). Na lista sai sem `steps`.
class AutomationRunSerializer < ApplicationSerializer
  attributes :id, :automation_id, :version, :status, :dry_run, :depth, :trigger, :error, :started_at, :finished_at, :resume_at, :steps
  attribute(:status_label, &:status_label)
end
