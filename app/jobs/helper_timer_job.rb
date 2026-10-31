# Fim de um tempo de helper (HelperTypes::Timer, HelperTypes::AlarmPanel).
# `stamp` = carimbo de quando foi agendado: pausou, cancelou ou reiniciou =
# job velho, o plugin não faz nada (`finish_due!`).
class HelperTimerJob < ApplicationJob
  queue_as :default

  def perform(point_id, stamp)
    point = ActsAsTenant.without_tenant { Point.find_by(id: point_id) } or return
    ActsAsTenant.with_tenant(point.tenant) { point.helper_type&.finish_due!(point, stamp) }
  end
end
