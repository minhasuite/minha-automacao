module Notifications
  module Digest
    # "Comandos com falha: 3 (Luz da sala, Portão)".
    class Failures < Section
      describe key: "failures", icon: "x-circle"

      def self.lines(_user, sites, range)
        names = Command.where(site_id: sites.map(&:id), status: "failed", created_at: range).joins(:point).pluck("points.name")
        return [] if names.empty?

        [ I18n.t("notifications.digest.failures", count: names.size, names: names.uniq.first(4).join(", ")) ]
      end
    end
  end
end
