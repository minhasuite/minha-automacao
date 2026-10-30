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

    # Botão do aviso (Lote 1): a primeira resposta vale e vira o evento das automações.
    def respond
      n = Notification.for_user(current_user).find(params[:id])
      ok = n.respond!(params[:action_id], current_user)
      redirect_to notifications_path, **(ok ? { notice: "Resposta enviada: #{n.response_title}." } : { alert: "Este aviso já foi respondido." })
    rescue ArgumentError
      redirect_to notifications_path, alert: "Botão inválido."
    end

    def read_all
      Notification.for_user(current_user).unread.update_all(read_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      redirect_to notifications_path, notice: "Tudo marcado como lido."
    end
  end
end
