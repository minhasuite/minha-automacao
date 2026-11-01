module Dashboards
  module Widgets
    # Alertas ativos (F5) com "Ciente"; depende dos pontos vigiados por regra.
    class AlertsWidget < Base
      describe type: "alerts", label: "Alertas ativos", icon: "exclamation-circle"

      def self.data(r, _w, _binds)
        helpers = ApplicationController.helpers
        open = r.site.alerts.active.includes(:alert_rule, :point).recent.limit(Resolver::LIST_LIMIT).to_a
        watched_ids = r.site.alert_rules.pluck(:point_id)
        watched = r.points.select { |p| watched_ids.include?(p.id) }
        [ { "alerts" => open.map do |a|
          { "id" => a.id, "title" => a.alert_rule.name, "severity" => a.alert_rule.severity, "point_id" => a.point_id,
            "text" => "#{a.point.name}: #{helpers.point_value_text(a.point)}", "opened_at" => a.opened_at, "acked" => a.acked?,
            "can_ack" => SiteMembership.allowed?(r.role, :command, risk: "sensitive") }
        end }, watched ]
      end
    end
  end
end
