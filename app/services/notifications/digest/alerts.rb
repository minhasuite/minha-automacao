module Notifications
  module Digest
    # "Alertas: 2 (Vazamento, Portão aberto há muito)".
    class Alerts < Section
      describe key: "alerts", icon: "exclamation-circle"

      def self.lines(_user, sites, range)
        names = Alert.where(site_id: sites.map(&:id), opened_at: range).includes(:alert_rule).map { |a| a.alert_rule.name }
        return [] if names.empty?

        [ I18n.t("notifications.digest.alerts", count: names.size, names: names.tally.map { |n, c| c > 1 ? "#{n} (#{c})" : n }.first(4).join(", ")) ]
      end
    end
  end
end
