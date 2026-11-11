module Api
  module V1
    # Regras de alerta (AlertRule).
    class AlertRulesController < AutomationController
      self.model = AlertRule
      self.fields = [ :name, :point_id, :operator, :value, :for_s, :severity, :repeat_s, :auto_resolve, :enabled, :message,
                      { escalation: [ :wait_s, { channels: [] } ] } ]
    end
  end
end
