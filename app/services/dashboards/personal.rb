module Dashboards
  # O que o painel resolvido ganha de cada pessoa (ideia 13), depois do cache
  # (que é por papel, não por pessoa):
  #
  # (O `search` de cada widget saiu em mobile-ajustes: a busca dentro do painel saiu da web e
  # do app no shell-sino; achar card é pela busca global, `Search::WidgetsSource`.)
  # - `favorites_now`: os pontos favoritos da pessoa neste local (a linha fixa
  #   no topo), já com o ponto em `points`. Favoritos em
  #   `users.dashboard_prefs["favorites"]` = {site_id → [ids]} (até `MAX`);
  #   o painel com `"favorites": false` não mostra a linha.
  module Personal
    MAX = 12
    KEY = "favorites".freeze

    module_function

    def apply!(payload, site:, user:, role:)
      payload["points"] ||= {}
      favorites!(payload, site, user, role) unless payload["favorites"] == false
      payload
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
