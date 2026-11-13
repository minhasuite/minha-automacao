module Api
  module V1
    class NotificationsController < BaseController
      # GET /notifications?unread=true&kind=&area_id=&level= — meta traz as
      # opções dos filtros (rótulos já no idioma) e o que está silenciado.
      def index
        scope = Notifications::Filter.apply(Notification.for_user(current_user), filter_params).order(created_at: :desc)
        records, meta = paginate(scope)
        choices = Notifications::Filter.choices(current_user)
        filters = choices.transform_values { |list| list.map { |v, l| { value: v, label: l } } }
        render_data(NotificationSerializer.new(records).to_h,
                    meta: meta.merge(unread_count: Notification.for_user(current_user).unread.count, filters: filters,
                                     mutes: Notifications::Settings.show(current_user)["mutes"], mute_hours: Notifications::MUTE_HOURS))
      end

      # PATCH /notifications/read { ids?: [...], kind?, area_id?, level? } — sem ids, marca as do filtro (todas sem filtro).
      def read_all
        scope = Notifications::Filter.apply(Notification.for_user(current_user), filter_params.except(:unread)).unread
        scope = scope.where(id: Array(params[:ids])) if params[:ids].present?
        count = scope.update_all(read_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        render_data({ marked: count, unread_count: Notification.for_user(current_user).unread.count })
      end

      # POST /notifications/:id/respond { action_id } — botão do aviso (Lote 1)
      # pelo app. A primeira resposta vale (409 already_responded depois) e
      # vira o evento `notification_action` das automações.
      def respond
        notification = Notification.for_user(current_user).find(params[:id])
        unless notification.respond!(params.require(:action_id), current_user)
          return render_error(:already_responded, "Este aviso já foi respondido.", status: :conflict)
        end

        render_data(NotificationSerializer.new(notification).to_h)
      rescue ArgumentError
        render_error(:invalid_action, "Botão inválido.", status: :unprocessable_content)
      end

      # POST /notifications/:id/mute { hours? } — silencia a automação/ponto do aviso para mim.
      def mute
        notification = Notification.for_user(current_user).find(params[:id])
        until_at = notification.mute!(current_user, params[:hours].to_i.presence_in(Notifications::MUTE_HOURS))
        return render_error(:nothing_to_mute, I18n.t("notifications.mute.nothing"), status: :unprocessable_content) unless until_at

        render_data({ key: notification.mute_key, label: notification.mute_label, until: until_at.iso8601 })
      end

      # DELETE /notifications/mutes { key }
      def unmute
        Notifications.unmute!(current_user, params.require(:key).to_s)
        render_data({ mutes: Notifications::Settings.show(current_user)["mutes"] })
      end

      # GET /notifications/digest — o resumo das últimas 24 h (mesmas partes do push).
      def digest = render_data({ sections: Notifications::Digest.build(current_user) })

      # GET/PATCH /notifications/preferences — silêncio, resumo, "silenciar" (e os da casa, se administrador).
      def preferences = render_data(Notifications::Settings.show(current_user))

      def update_preferences
        Notifications::Settings.update(current_user, params.permit(:quiet_enabled, :quiet_from, :quiet_to, :digest_enabled, :digest_at, :mute_hours,
                                                                   :house_quiet_enabled, :house_quiet_from, :house_quiet_to, :merge_s))
        render_data(Notifications::Settings.show(current_user.reload))
      end

      # PATCH /notifications/:id/read
      def read
        notification = Notification.for_user(current_user).find(params[:id])
        notification.update!(read_at: notification.read_at || Time.current)
        render_data(NotificationSerializer.new(notification).to_h)
      end

      private

      def filter_params = params.permit(:kind, :area_id, :level, :unread).to_h.symbolize_keys
    end
  end
end
