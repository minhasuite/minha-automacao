# Retenção das gravações das câmeras (ondaC2, C10), a cada hora.
class RecordingsPurgeJob < ApplicationJob
  queue_as :default

  def perform = Recordings.purge!
end
