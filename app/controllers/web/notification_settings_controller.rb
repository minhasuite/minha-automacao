module Web
  # Configurações → Notificações: horário de silêncio, resumo diário, tempo do
  # "silenciar" e o que está silenciado (de cada pessoa); silêncio dos canais
  # da casa e janela de juntar avisos (administradores). docs/push.md.
  class NotificationSettingsController < ApplicationController
    def show
      @prefs = Notifications.user_prefs(current_user)
      @house = Notifications.house_prefs(current_user.tenant) if current_user.admin?
      @mutes = Notifications.mute_list(current_user)
    end

    def update
      Notifications::Settings.update(current_user, params.require(:prefs).permit(
        :quiet_enabled, :quiet_from, :quiet_to, :digest_enabled, :digest_at, :mute_hours,
        :house_quiet_enabled, :house_quiet_from, :house_quiet_to, :merge_s
      ))
      redirect_to settings_notifications_path, notice: t("notifications.settings.saved")
    end
  end
end
