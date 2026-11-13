module Dashboards
  module Widgets
    # Cartão da área (F5): os itens (`facts`, P1.1) são consultas do
    # `Points::Query` com a área injetada; sem `facts` no widget, vale o padrão
    # do local (Configurações → Painéis → Padrões; nasce com ligados, abertos,
    # movimento, potência e sem sinal, em `Facts::AREA_DEFAULTS`). O que existe
    # é a regra única do `Points::Query.exists?`. Navega para a view com `area`
    # igual; tocar num item abre a lista dos pontos dele (ideia 14).
    #
    # `data`: `facts` prontos + `caption` (sem item nenhum) e, para o app
    # antigo, `on`/`open`/`motion`/`power`/`unavailable`/`total` tirados dos
    # fatos de mesmo id.
    class AreaCardWidget < Base
      describe type: "area_card", label: "Área", icon: "home", required: %w[area], params: %w[area]
      texts en: { label: "Area" },
            es: { label: "Área" }

      LEGACY = { "on" => "on", "open" => "open", "motion" => "motion", "power" => "power", "unavailable" => "offline" }.freeze

      def self.errors(w) = w.key?("facts") ? Facts.errors(w["facts"]) : []

      def self.data(r, w, _binds)
        area = r.area(w["area"])
        return [ { "missing" => true }, [] ] unless area

        scope = { "area" => area.id }
        inside = r.query(scope)
        url = ->(fact) { drill_url(r, w, fact) }
        facts, deps = Facts.resolve(r, facts_for(r, w), scope: scope, url: url)
        view = Array(r.definition["views"]).find { |v| v["area"] == area.id }
        by_id = facts.index_by { |f| f["id"] }
        legacy = LEGACY.to_h { |k, id| [ k, by_id.dig(id, "value") ] }
        [ { "area" => { "id" => area.id, "name" => area.name, "icon" => area.icon, "background" => area.background },
            "view_id" => view&.dig("id"), "facts" => facts, "total" => inside.size,
            "caption" => I18n.t("dashboards.ed.points", count: inside.size),
            "on" => legacy["on"].to_i, "open" => legacy["open"].to_i, "motion" => legacy["motion"] == true,
            "power" => legacy["power"], "unavailable" => legacy["unavailable"].to_i }, (r.query(scope, with_state: false) + deps).uniq ]
      end

      def self.facts_for(r, w) = w["facts"].is_a?(Array) ? w["facts"] : Facts.area_defaults(r.site)

      # Ideia 14: os pontos de um item (o toque no "6 sem sinal").
      def self.drill(r, w, key)
        area = r.area(w["area"]) or return nil
        fact = facts_for(r, w).find { |f| f["id"] == key } or return nil
        { "title" => Facts.one(fact, Facts.points(r, fact, scope: { "area" => area.id }), nil)&.dig("text") || area.name,
          "subtitle" => area.name, "points" => Facts.points(r, fact, scope: { "area" => area.id }) }
      end

      def self.attrs(p, site = nil)
        own = p[:own_facts] == "1" ? Facts.from_form(p[:facts] || {}) : nil
        super.merge("facts" => own.presence).compact
      end

      # Linhas numeradas do formulário ("0".."7") com os campos de cada item.
      def self.permit = [ :area, :own_facts, { facts: Facts::FORM_FIELDS } ]

      def self.form = "web/dashboards/widget_forms/area_card"
    end
  end
end
