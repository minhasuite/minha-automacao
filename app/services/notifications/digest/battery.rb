module Notifications
  module Digest
    # "Bateria baixa: Sensor da porta (12%)": aparelhos com ponto de bateria abaixo de LOW.
    class Battery < Section
      LOW = 20
      describe key: "battery", icon: "lightning-bolt"

      def self.lines(_user, sites, _range)
        devices = Device.where(site_id: sites.map(&:id), disabled: false).where.not(battery_point_id: nil).to_a
        levels = Point.where(id: devices.map(&:battery_point_id)).to_h { |p| [ p.id, p.value ] }
        low = devices.filter_map { |d| (v = levels[d.battery_point_id]).is_a?(Numeric) && v <= LOW ? "#{d.name} (#{v.round}%)" : nil }
        low.any? ? [ I18n.t("notifications.digest.battery", names: low.first(6).join(", ")) ] : []
      end
    end
  end
end
