module Web
  # Central de notificações: filtros por tipo, área e nível, marcar tudo como
  # lido (o que o filtro mostra), silenciar a origem do aviso por X horas e o
  # resumo do dia (docs/push.md, "Menos ruído"). O sino do topo (web/notifications/_bell, shell-sino) lê
  # `recent` (os últimos, no frame do popover) e `count` (o contador, JSON).
  class NotificationsController < ApplicationController
    RECENT = 8

    # ?arquivadas=1: a aba Arquivadas da central (v1.14.2), com o Desarquivar.
    def index
      @archived = params[:arquivadas].present?
      @filters = Notifications::Filter.active(filter_params)
      @choices = Notifications::Filter.choices(current_user)
      @mutes = Notifications.mute_list(current_user)
      mine = Notification.for_user(current_user)
      scope = Notifications::Filter.apply(@archived ? mine.archived : mine.active, @filters)
      @pagy, @notifications = pagy(scope.order(created_at: :desc))
      @unread = scope.unread.count
      # Alertas ainda abertos dos avisos desta página: o "Ciente" vai no próprio aviso.
      ids = @notifications.filter_map { |n| n.data.to_h["alert_id"] if n.kind == "alerta" }
      @alerts = Alert.where(id: ids, site_id: Site.visible_to(current_user).select(:id)).includes(:site).index_by(&:id)
    end

    # Sino: os últimos avisos (frame do popover; os links vão para a página inteira).
    def recent
      @notifications = Notification.for_user(current_user).active.order(created_at: :desc).limit(RECENT)
      render layout: false
    end

    def count
      render json: { count: helpers.unread_notifications }
    end

    # Abrir a notificação marca como lida. Pelo sino (`open=1`), leva ao destino do aviso (caminho interno) ou
    # a ele na central.
    def read
      n = Notification.for_user(current_user).find(params[:id])
      n.update!(read_at: n.read_at || Time.current)
      return redirect_to(notifications_path) unless params[:open].present?

      url = n.open_url
      redirect_to(url&.start_with?("/") ? url : notifications_path(anchor: helpers.notification_anchor(n)))
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
      # Pelo sino (`back=1`): fica na tela em que a pessoa estava.
      return redirect_back_or_to(notifications_path, notice: t("automations.flash.all_read")) if params[:back].present?

      redirect_to notifications_path(filters), notice: t("automations.flash.all_read")
    end

    # Sai da lista e do sino. O desfazer é da central (archive_undo: o POST só vem depois do tempo sem desfazer).
    def archive
      Notification.for_user(current_user).find(params[:id]).archive!
      redirect_to notifications_path
    end

    # O "Desarquivar" da aba Arquivadas.
    def unarchive
      Notification.for_user(current_user).find(params[:id]).unarchive!
      redirect_to notifications_path(arquivadas: 1), notice: t("notifications.archive.undone")
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
