module Web
  # ondaA2 A18: instalar a atualização de firmware de um aparelho (ponto `update`).
  class FirmwareController < ApplicationController
    def create
      point = Point.find(params[:point_id])
      raise ActiveRecord::RecordNotFound unless point.capability == "update"

      authorize_site!(point.site, :manage)
      Firmware.install!(point, user: current_user)
      redirect_back fallback_location: settings_system_path, notice: t("firmware.started", name: point.device.name)
    rescue Firmware::Error => e
      redirect_back fallback_location: settings_system_path, alert: e.message
    end
  end
end
