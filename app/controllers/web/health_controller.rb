module Web
  # Saúde do sistema (Configurações → Saúde): cada verificação do registro
  # `Health::CHECKS` com seus itens. Só administradores (membro nem vê que existe).
  # O dono da casa também conecta aqui o Google Drive do backup.
  class HealthController < ApplicationController
    def show
      raise ActiveRecord::RecordNotFound unless current_user.admin?

      @results = Health.run(current_user.tenant)
      @status = Health.worst(@results.map(&:status))
      drive = Backups::Destinations::GoogleDrive
      return unless drive.manageable_by?(current_user) && Calendars::Google.configured?

      @drive = { connected: drive.connected?, email: drive.email, status: Backups.status }
      @drive[:auth_url] = Calendars::Google.auth_url(integrations_oauth_callback_url, Integrations.oauth_state(drive.state_for(current_user)), scope: drive::SCOPE)
    end

    def disconnect_drive
      raise ActiveRecord::RecordNotFound unless Backups::Destinations::GoogleDrive.manageable_by?(current_user)

      Backups::Destinations::GoogleDrive.disconnect!
      redirect_to settings_health_path, notice: t("health.drive.disconnected")
    end
  end
end
