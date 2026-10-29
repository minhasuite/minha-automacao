module Web
  # Espelhamento entre pontos (PointLink).
  class PointLinksController < AutomationController
    self.model = PointLink
    self.label = "Espelhamento"

    private

    def defaults = { source_point_id: params[:point_id] }
    def permitted = %i[source_point_id target_point_id mode bidirectional trigger_value enabled]
  end
end
