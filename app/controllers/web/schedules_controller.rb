module Web
  # Agenda por horário ou sol (Schedule).
  class SchedulesController < AutomationController
    self.model = Schedule
    self.label = "Agenda"

    private

    def defaults = { point_id: params[:point_id], command: "on", time_of_day: "17:00" }
    def permitted = [ :name, :kind, :time_of_day, :offset_min, :point_id, :scene_id, :command, :value, :enabled, { days: [] } ]
  end
end
