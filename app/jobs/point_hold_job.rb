# Sensor de pulso (Lote 3): ponto que só recebe o "ligou" (movimento da
# câmera Tuya, botão) volta a falso `address.hold_s` segundos depois do
# último aviso. O carimbo `reported_at` dispensa cancelar: aviso novo
# agenda outro e o antigo não age.
class PointHoldJob < ApplicationJob
  queue_as :default

  def self.schedule(point) = set(wait: point.address["hold_s"].to_i.clamp(1, 3600).seconds).perform_later(point.id, point.reported_at.iso8601(6))

  def perform(point_id, reported_at)
    point = ActsAsTenant.without_tenant { Point.find_by(id: point_id) } or return
    ActsAsTenant.with_tenant(point.tenant) do
      point.report!(false, quality: point.quality) if point.value == true && point.reported_at&.iso8601(6) == reported_at
    end
  end
end
