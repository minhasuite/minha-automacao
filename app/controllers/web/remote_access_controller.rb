module Web
  # Configurações → Acesso remoto (produto): escolher o provedor, ligar e
  # desligar com o estado. Ver: administrador; mudar: dono.
  class RemoteAccessController < ApplicationController
    before_action -> { raise ActiveRecord::RecordNotFound unless current_user.admin? }
    before_action :require_owner!, only: %i[update destroy]

    def show
      @status = RemoteAccess.status(current_user.tenant)
    end

    def update
      RemoteAccess.enable!(current_user.tenant, params[:provider], params.fetch(:remote, {}))
      redirect_to settings_remote_path, notice: t("remote.enabled")
    rescue RemoteAccess::Error => e
      redirect_to settings_remote_path, alert: e.message
    end

    def destroy
      RemoteAccess.disable!(current_user.tenant)
      redirect_to settings_remote_path, notice: t("remote.disabled")
    rescue RemoteAccess::Error => e
      redirect_to settings_remote_path, alert: e.message
    end
  end
end
