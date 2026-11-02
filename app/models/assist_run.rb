# Uma execução do pipeline do Assist (ondaB1, B5; a depuração do HA): de
# onde veio, o que ouviu, a intenção, a resposta e cada etapa (STT, intenção,
# TTS) com motor, tempo e erro. Guarda as últimas KEEP por local; nunca o
# áudio.
class AssistRun < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :site
  belongs_to :pipeline, class_name: "AssistPipeline", optional: true
  belongs_to :user, optional: true

  KEEP = 100
  SOURCES = %w[web app satellite api mcp].freeze

  validates :source, inclusion: { in: SOURCES }

  after_create_commit :prune

  private

  def prune
    old = AssistRun.where(site_id: site_id).order(created_at: :desc).offset(KEEP).pluck(:id)
    AssistRun.where(id: old).delete_all if old.any?
  end
end
