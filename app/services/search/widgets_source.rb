module Search
  # Cards dos painéis publicados: "em qual painel e visão" está o card (rótulo, título
  # ou o nome do ponto). Abre o painel na visão, com o card em foco (âncora). Só o
  # que o papel vê (painel e `visible_if.role` da visão e do card); card sem nome próprio fica de fora.
  class WidgetsSource < Source
    MAX_WIDGETS = 400

    def self.prefix = "widget"

    def self.call(q, ctx)
      return [] if q.verb

      entries(ctx).select { |e| match?(q, e[:title], e[:dashboard].name, e[:view]["title"]) }.first(CANDIDATES).map { |e| build(e) }
    end

    # id = "<painel>/<visão>/<widget>"
    def self.lookup(id, ctx)
      d_id, v_id, w_id = id.split("/", 3)
      e = entries(ctx, only: d_id).find { |x| x[:view]["id"] == v_id && x[:widget]["id"] == w_id } and build(e)
    end

    def self.entries(ctx, only: nil)
      dashboards = Dashboard.where(site_id: ctx.site_ids).then { |s| only ? s.where(id: only) : s }.ordered.select { |d| d.visible_to?(ctx.roles[d.site_id]) }
      names = Point.where(site_id: dashboards.map(&:site_id).uniq).pluck(:id, :name).to_h
      dashboards.flat_map do |d|
        role = ctx.roles[d.site_id]
        Array((d.auto? ? {} : d.definition.to_h)["views"]).select { |v| v.is_a?(Hash) && Dashboards.role_ok?(v["visible_if"], role) }.flat_map do |v|
          Dashboards::Resolver.flatten([ *Array(v["badges"]), *Array(v["sections"]).flat_map { |s| Array(s["widgets"]) } ]).first(MAX_WIDGETS).filter_map do |w|
            next unless Dashboards.role_ok?(w["visible_if"], role)

            title = w["label"].presence || w["title"].presence || names[w["bind"]]
            { dashboard: d, view: v, widget: w, title: title } if title.present? && w["id"].present?
          end
        end
      end
    end

    def self.build(e)
      d, v, w = e.values_at(:dashboard, :view, :widget)
      Result.new(kind: I18n.t("search.kinds.widget"), title: e[:title], subtitle: [ d.name, v["title"] ].compact_blank.join(" · "),
                 icon: w["icon"].presence || Dashboards::Widgets[w["type"]]&.icon || "view-grid",
                 url: dashboard_path(d, view: v["path"].presence || v["id"], anchor: w["id"]), key: "#{prefix}:#{d.id}/#{v['id']}/#{w['id']}",
                 target: { type: "dashboard", id: d.id, site_id: d.site_id, view: v["id"], widget_id: w["id"] })
    end
  end
end
