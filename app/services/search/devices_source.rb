module Search
  # Aparelhos (nome, fabricante/modelo, área, integração), sem os virtuais internos
  # (Automações, Helpers, Scripts) e os removidos da conta.
  class DevicesSource < Source
    INTERNAL = [ AutomationPoints::DEVICE_ID, "helpers", "scripts" ].freeze

    def self.prefix = "device"

    def self.call(q, ctx)
      return [] if q.verb

      areas = PointsSource.areas_for(ctx)
      scope(ctx).select { |d| match?(q, d.name, areas[d.area_id], d.manufacturer, d.model, d.driver_label) }
                .first(CANDIDATES).map { |d| build(d, areas) }
    end

    def self.lookup(id, ctx) = (d = scope(ctx).find_by(id: id)) && build(d, PointsSource.areas_for(ctx))

    def self.scope(ctx)
      Device.where(site_id: ctx.site_ids, removed_at: nil).where("devices.external_id IS NULL OR devices.external_id NOT IN (?)", INTERNAL).order(:name).limit(2000)
    end

    def self.build(d, areas)
      Result.new(kind: I18n.t("search.kinds.device"), title: d.name, subtitle: [ areas[d.area_id], d.driver_label ].compact_blank.join(" · "),
                 icon: "chip", url: device_path(d), key: "#{prefix}:#{d.id}")
    end
  end
end
