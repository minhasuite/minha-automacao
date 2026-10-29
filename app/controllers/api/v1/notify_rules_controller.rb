module Api
  module V1
    # Avisos (NotifyRule).
    class NotifyRulesController < AutomationController
      self.model = NotifyRule
      self.fields = [ :point_id, :to_value, :message, :enabled, { channels: [] } ]
    end
  end
end
