module Api
  module V1
    # Agendas (Schedule).
    class SchedulesController < AutomationController
      self.model = Schedule
      self.fields = [ :name, :kind, :time_of_day, :offset_min, :point_id, :scene_id, :command, :value, :enabled, { days: [] } ]
    end
  end
end
