module Notifications
  module Digest
    # "Portão: Aberto 6 vezes": pontos com aviso ou alerta ligados que ficaram
    # verdadeiros (ou "open") no período, pelo histórico.
    class Openings < Section
      describe key: "openings", icon: "switch-horizontal"

      def self.lines(_user, sites, range)
        ids = NotifyRule.where(site_id: sites.map(&:id), enabled: true).pluck(:point_id) |
              AlertRule.where(site_id: sites.map(&:id), enabled: true).pluck(:point_id)
        points = Point.where(id: ids).index_by(&:id)
        counts = Reading.where(point_id: points.keys, at: range).where("value = 1 OR value_text = 'open'").group(:point_id).count
        counts.sort_by { |_, n| -n }.first(5).map do |id, n|
          point = points[id]
          I18n.t("notifications.digest.opening", name: point.name, value: on_text(point), count: n)
        end
      end

      def self.on_text(point)
        probe = point.dup
        probe.value = point.capability == "gate" ? "open" : true
        ApplicationController.helpers.point_value_text(probe)
      end
    end
  end
end
