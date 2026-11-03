# Um trecho gravado de uma câmera (ondaC2, C10): arquivo MP4 em
# `Recordings.root(site)/<file>`; some com a retenção (`Recordings.purge!`).
class CameraRecording < ApplicationRecord
  acts_as_tenant :tenant

  TRIGGERS = %w[continuous event manual].freeze

  belongs_to :site
  belongs_to :point

  validates :trigger, inclusion: { in: TRIGGERS }
  validates :file, presence: true

  before_validation { self.tenant_id ||= site&.tenant_id }

  def ended_at = started_at + duration_s
  def path = MediaSources.safe_join(Recordings.root(site_id), file)
end
