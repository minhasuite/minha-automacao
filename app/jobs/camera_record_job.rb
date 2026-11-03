# Gravação na fila (ondaC2, C10): evento de movimento ou comando `record`.
class CameraRecordJob < ApplicationJob
  queue_as :default

  def perform(point_id, seconds, trigger)
    point = ActsAsTenant.without_tenant { Point.find_by(id: point_id) } or return
    ActsAsTenant.with_tenant(point.tenant) { Recordings.record!(point, seconds.to_i, trigger) }
  rescue Recordings::Error => e
    Rails.logger.warn("[gravacao] #{point_id}: #{e.message}")
  end
end
