# Retenção das gravações das câmeras (ondaC2, C10), a cada hora.
class RecordingsPurgeJob < ApplicationJob
  include SlowJob

  def perform = Recordings.purge!
end
