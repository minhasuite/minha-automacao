# ondaC1 (C6): manda o estado novo de um ponto aos relatores do StateReport (Google Home…).
class StateReportJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(point_id, reporters)
    point = ActsAsTenant.without_tenant { Point.find(point_id) }
    ActsAsTenant.with_tenant(point.tenant) do
      StateReport.reporters.select { |r| reporters.include?(r.name) }.each do |r|
        r.report!(point.site, [ point ])
      rescue StandardError => e
        Rails.logger.warn("[state_report] #{r.name}: #{e.message}")
      end
    end
  end
end
