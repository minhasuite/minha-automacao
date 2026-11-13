module Search
  class DashboardsSource < Source
    def self.prefix = "dashboard"

    def self.call(q, ctx)
      return [] if q.verb

      visible(ctx).select { |d| match?(q, d.name, "painel") }.first(CANDIDATES).map { |d| build(d) }
    end

    def self.lookup(id, ctx) = (d = visible(ctx).find { |x| x.id == id }) && build(d)
    def self.visible(ctx) = Dashboard.where(site_id: ctx.site_ids).ordered.select { |d| d.visible_to?(ctx.roles[d.site_id]) }

    def self.build(d)
      Result.new(kind: I18n.t("search.kinds.dashboard"), title: d.name, icon: d.icon_name, url: dashboard_path(d), key: "#{prefix}:#{d.id}",
                 target: { type: "dashboard", id: d.id, site_id: d.site_id })
    end
  end
end
