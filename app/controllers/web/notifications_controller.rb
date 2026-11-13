module Web
  # Central de notificações: filtros por tipo, área e nível, marcar tudo como
  # lido (o que o filtro mostra), silenciar a origem do aviso por X horas e o
  # resumo do dia (docs/push.md, "Menos ruído").
  class NotificationsController < ApplicationController
    def index
      @filters = Notifications::Filter.active(filter_params)
      @choices = Notifications::Filter.choices(current_user)
      @mutes = Notifications.mute_list(current_user)
      @pagy, @notifications = pagy(Notifications::Filter.apply(Notification.for_user(current_user), @filters).order(created_at: :desc))
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
      redirect_to notifications_path, **(ok ? { notice: t("automations.flash.replied", title: n.response_title) } : { alert: t("automations.flash.already_replied") })
    rescue ArgumentError
      redirect_to notifications_path, alert: t("automations.flash.bad_button")
    end

    def read_all
      filters = Notifications::Filter.active(filter_params)
      Notifications::Filter.apply(Notification.for_user(current_user), filters).unread.update_all(read_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      redirect_to notifications_path(filters), notice: t("automations.flash.all_read")
    end

    # Silencia a automação/ponto deste aviso para mim por `hours`.
    def mute
      n = Notification.for_user(current_user).find(params[:id])
      until_at = n.mute!(current_user, params[:hours].to_i.presence_in(Notifications::MUTE_HOURS))
      return redirect_to(notifications_path, alert: t("notifications.mute.nothing")) unless until_at

      redirect_to notifications_path, notice: t("notifications.mute.done", name: n.mute_label, until: l(until_at.in_time_zone(zone), format: :short))
    end

    def unmute
      Notifications.unmute!(current_user, params[:key].to_s)
      redirect_back_or_to notifications_path, notice: t("notifications.mute.undone")
    end

    def digest
      @parts = Notifications::Digest.build(current_user)
    end

    private

    def filter_params = params.permit(:kind, :area_id, :level, :unread)
    def zone = Notifications.zone(current_user.tenant)
  end
end
