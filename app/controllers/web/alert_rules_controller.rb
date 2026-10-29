module Web
  # Regra de alerta com escalonamento (AlertRule).
  class AlertRulesController < AutomationController
    self.model = AlertRule
    self.label = "Alerta"

    private

    def defaults = { point_id: params[:point_id], value: true, for_s: 300 }
    def permitted = [ :name, :point_id, :operator, :value, :for_min, :severity, :repeat_min, :auto_resolve, :enabled,
                      { steps: [ :wait_min, { channels: [] } ] } ]
  end
end
