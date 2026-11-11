module Dashboards
  # O que o painel resolvido ganha de cada pessoa (ideia 13), depois do cache
  # (que é por papel, não por pessoa):
  #
  # - `search` em cada widget: o texto que a busca dentro do painel procura
  #   (rótulo, título, nomes dos pontos e das áreas). A web filtra pelo
  #   `ss-filter` da gem e o app pelo mesmo texto: nenhum dos dois monta regra.
  # - `favorites_now`: os pontos favoritos da pessoa neste local (a linha fixa
  #   no topo), já com o ponto em `points`. Favoritos em
  #   `users.dashboard_prefs["favorites"]` = {site_id → [ids]} (até `MAX`);
  #   o painel com `"favorites": false` não mostra a linha.
  module Personal
    MAX = 12
    KEY = "favorites".freeze

    module_function

    def apply!(payload, site:, user:, role:)
      areas = site.areas.pluck(:id, :name).to_h
      points = payload["points"] ||= {}
      Array(payload["views"]).each do |v|
        each_widget([ *Array(v["badges"]), *Array(v["sections"]).flat_map { |s| Array(s["widgets"]) } ]) do |w|
          w["search"] = search_text(w, points, areas)
        end
      end
      favorites!(payload, site, user, role) unless payload["favorites"] == false
      payload
    end

    def each_widget(list, &block)
      list.each do |w|
        yield w
        each_widget(Array(w["widgets"]), &block)
      end
    end

    def search_text(w, points, areas)
      ids = [ *w["deps"], *Array(w.dig("data", "point_ids")) ].uniq
      names = ids.filter_map { |id| (p = points[id]) && [ p["name"], p["title"], p["device"], areas[p["area_id"]] ] }.flatten
      [ w["label"], w["title"], w.dig("data", "title"), areas[w["area"]], *names ].compact_blank.map(&:to_s).uniq.join(" ").first(500)
    end

    def ids(user, site) = Array(user&.dashboard_prefs.to_h.dig(KEY, site.id))

    def favorites!(payload, site, user, role)
      wanted = ids(user, site)
      return payload["favorites_now"] = [] if wanted.empty?

      found = site.points.where(id: wanted).includes(:device).index_by(&:id)
      list = wanted.filter_map { |id| (p = found[id]) && Points::Query.exists?(p) ? p : nil }
      list.each { |p| payload["points"][p.id] ||= Resolver.point_json(p, role) }
      payload["favorites_now"] = list.map(&:id)
    end

    def favorite?(user, point) = ids(user, point.site).include?(point.id)

    # Liga/desliga o favorito (`on`: true/false; nil = alterna). → favorito agora?
    def toggle!(user, point, on = nil)
      list = ids(user, point.site)
      on = !list.include?(point.id) if on.nil?
      list = on ? (list - [ point.id ] + [ point.id ]).last(MAX) : list - [ point.id ]
      prefs = user.dashboard_prefs.to_h
      user.update!(dashboard_prefs: prefs.merge(KEY => prefs.fetch(KEY, {}).to_h.merge(point.site_id => list)))
      on
    end
  end
end
