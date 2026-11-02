module Search
  class DashboardsSource < Source
    def self.call(q, ctx)
      return [] if q.verb

      Dashboard.where(site_id: ctx.site_ids).ordered.select { |d| d.visible_to?(ctx.roles[d.site_id]) && match?(q, d.name, "painel") }.first(LIMIT)
               .map { |d| Result.new(kind: "Painel", title: d.name, icon: d.icon_name, url: dashboard_path(d)) }
    end
  end
end
