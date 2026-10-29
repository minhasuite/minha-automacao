module Web
  # Aviso quando o ponto muda (NotifyRule).
  class NotifyRulesController < AutomationController
    self.model = NotifyRule
    self.label = "Aviso"

    private

    def defaults = { point_id: params[:point_id] }
    def permitted = [ :point_id, :to_value, :message, :enabled, { channels: [] } ]
  end
end
