module Api
  module V1
    # Espelhamentos (PointLink).
    class PointLinksController < AutomationController
      self.model = PointLink
      self.fields = %i[source_point_id target_point_id mode bidirectional trigger_value enabled]
    end
  end
end
