# Fim de um temporizador (HelperTypes::Timer). `stamp` = finishes_at de quando
# foi agendado: pausou, cancelou ou reiniciou = job velho, não faz nada.
class HelperTimerJob < ApplicationJob
  queue_as :default

  def perform(point_id, stamp)
    point = ActsAsTenant.without_tenant { Point.find_by(id: point_id) } or return
    ActsAsTenant.with_tenant(point.tenant) { HelperTypes::Timer.finish_due!(point, stamp) }
  end
end
