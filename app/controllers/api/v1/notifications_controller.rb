module Api
  module V1
    class NotificationsController < BaseController
      # GET /notifications?unread=true
      def index
        scope = Notification.for_user(current_user).order(created_at: :desc)
        scope = scope.unread if bool(params[:unread])
        records, meta = paginate(scope)
        render_data(NotificationSerializer.new(records).to_h, meta: meta.merge(unread_count: Notification.for_user(current_user).unread.count))
      end

      # PATCH /notifications/read { ids?: [...] } — sem ids, marca todas.
      def read_all
        scope = Notification.for_user(current_user).unread
        scope = scope.where(id: Array(params[:ids])) if params[:ids].present?
        count = scope.update_all(read_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        render_data({ marked: count, unread_count: Notification.for_user(current_user).unread.count })
      end

      # PATCH /notifications/:id/read
      def read
        notification = Notification.for_user(current_user).find(params[:id])
        notification.update!(read_at: notification.read_at || Time.current)
        render_data(NotificationSerializer.new(notification).to_h)
      end
    end
  end
end
