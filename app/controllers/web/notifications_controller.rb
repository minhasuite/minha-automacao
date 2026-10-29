module Web
  class NotificationsController < ApplicationController
    def index
      @pagy, @notifications = pagy(Notification.for_user(current_user).order(created_at: :desc))
    end

    # Abrir a notificação marca como lida.
    def read
      n = Notification.for_user(current_user).find(params[:id])
      n.update!(read_at: n.read_at || Time.current)
      redirect_to notifications_path
    end

    def read_all
      Notification.for_user(current_user).unread.update_all(read_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      redirect_to notifications_path, notice: "Tudo marcado como lido."
    end
  end
end
