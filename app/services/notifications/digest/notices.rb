module Notifications
  module Digest
    # "Avisos: 14 (3 silenciados por você)".
    class Notices < Section
      describe key: "notices", icon: "bell"

      def self.lines(user, _sites, range)
        scope = Notification.for_user(user).where(created_at: range).where.not(kind: "resumo_diario")
        n = scope.sum("GREATEST(COALESCE(jsonb_array_length(CASE WHEN jsonb_typeof(notifications.data->'entries') = 'array' THEN notifications.data->'entries' END), 1), 1)")
        n.positive? ? [ I18n.t("notifications.digest.notices", count: n) ] : []
      end
    end
  end
end
