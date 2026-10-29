# Manutenção diária do histórico: cria a partição do mês seguinte, apaga as
# partições velhas, as leituras além do `retention_days` de cada ponto e os
# comandos/eventos com mais de um ano.
class ReadingsMaintenanceJob < ApplicationJob
  queue_as :default

  def perform(now = Time.current)
    Reading.ensure_partitions!(now)
    Reading.drop_old_partitions!(now)
    ActsAsTenant.without_tenant do
      Point.where.not(retention_days: nil).find_each do |p|
        Reading.where(point_id: p.id, at: ...(now - p.retention_days.days)).delete_all
        ReadingRollup.where(point_id: p.id, bucket: "1h", starts_at: ...(now - p.retention_days.days)).delete_all
      end
      Command.where(created_at: ...(now - Command::RETENTION_DAYS.days)).delete_all
      Event.where(at: ...(now - Event::RETENTION_DAYS.days)).delete_all
    end
  end
end
