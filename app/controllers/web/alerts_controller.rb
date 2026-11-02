module Web
  # Central de alertas: os abertos (com "Ciente") e os últimos resolvidos dos
  # locais que a pessoa vê. Ciente: operador ou acima.
  class AlertsController < ApplicationController
    def index
      scope = Alert.where(site_id: Site.visible_to(current_user).select(:id)).includes(:alert_rule, :point, :site, :acked_by).recent
      @open = scope.active.to_a
      @closed = scope.where.not(resolved_at: nil).limit(20).to_a
    end

    def ack
      alert = Alert.find(params[:id])
      authorize_site!(alert.site, :command, risk: "sensitive")
      alert.ack!(current_user)
      redirect_to alerts_path, notice: t("automations.flash.alert_ack")
    end
  end
end
