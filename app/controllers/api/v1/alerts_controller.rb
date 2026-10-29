module Api
  module V1
    # Central de alertas: GET /alerts?status=open|all (padrão: abertos) dos
    # locais que a pessoa vê; POST /alerts/:id/ack ("ciente", operador ou acima).
    class AlertsController < BaseController
      def index
        scope = Alert.where(site_id: Site.visible_to(current_user).select(:id)).includes(:alert_rule, :point).recent
        scope = scope.active unless params[:status] == "all"
        records, meta = paginate(scope)
        render_data(records.map { |a| serialize(a) }, meta: meta)
      end

      def show
        alert = Alert.find(params[:id])
        authorize_site!(alert.site, :view)
        render_data(serialize(alert))
      end

      def ack
        alert = Alert.find(params[:id])
        authorize_site!(alert.site, :command, risk: "sensitive")
        alert.ack!(current_user)
        render_data(serialize(alert))
      end

      private

      def serialize(a)
        a.as_json(except: "tenant_id").merge("name" => a.alert_rule.name, "severity" => a.alert_rule.severity,
                                             "point_name" => a.point.name, "point_value" => a.point.value)
      end
    end
  end
end
