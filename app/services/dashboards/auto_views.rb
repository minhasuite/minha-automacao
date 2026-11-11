module Dashboards
  # Visão automática (ideia 6 da proposta de personalização): uma visão com a
  # marca `auto` se monta sozinha a cada leitura, então aparelho novo da área
  # entra sem ninguém mexer, até o dono "congelar" (a marca sai e a visão fica
  # como estava, normal, editável).
  #
  #   { "id" => "auto-cozinha", "title" => "Cozinha", "area" => "<id>", "auto" => { "area" => "<id>" }, "sections" => [...] }
  #   { "id" => "home", "title" => "Início", "auto" => { "home" => true, "areas" => ["<id>", ...] }, "sections" => [...] }
  #
  # `area`: a visão da área (`Generator#view_for_area`) arrumada pelas regras
  # do painel/local (`RoomLayout`, a não ser com `"arrange" => false`);
  # `home`: o Início do painel automático (cartões só das `areas`, se houver).
  # Título, ícone, tema, topo e caminho continuam os da visão; seções e selos
  # são refeitos. Os ids levam o id da visão na frente (`<visão>--<id>`) para
  # não bater com outra visão do mesmo painel. Não grava nada: `expand`
  # devolve a definição com as visões refeitas (`Dashboard#published` e
  # `#working_draft` chamam).
  module AutoViews
    KEYS = %w[area home areas arrange].freeze

    module_function

    def auto?(view) = view.is_a?(Hash) && view["auto"].is_a?(Hash)

    def expand(defn, site)
      return defn unless defn.is_a?(Hash) && Array(defn["views"]).any? { |v| auto?(v) }

      ctx = {}
      defn.merge("views" => defn["views"].map { |v| auto?(v) ? fill(v, site, defn, ctx) : v })
    end

    def fill(view, site, defn, ctx)
      auto = view["auto"]
      gen = (ctx[:gen] ||= {})[Array(auto["areas"]).sort] ||= Generator.new(site, areas: auto["areas"].presence)
      fresh = if auto["home"] then gen.home
      elsif (area = (ctx[:areas] ||= site.areas.index_by(&:id))[auto["area"]]) then gen.view_for_area(area)
      end
      fresh = (fresh || {}).merge("id" => view["id"], "sections" => Array(fresh&.dig("sections")))
      fresh = (ctx[:layout] ||= RoomLayout.new(site, rules: Arrange.rules(site, defn))).view(fresh).first if auto["area"] && auto["arrange"] != false
      view.merge("badges" => prefix(view["id"], Array(fresh["badges"]).presence || []).presence,
                 "sections" => prefix(view["id"], fresh["sections"])).compact
    end

    # Ids com o da visão na frente (pilha/grade também).
    def prefix(vid, list)
      list.map do |node|
        out = node.merge("id" => node["id"].to_s.start_with?("#{vid}--") ? node["id"] : "#{vid}--#{node['id']}".first(100))
        out["widgets"] = prefix(vid, node["widgets"]) if node["widgets"].is_a?(Array)
        out
      end
    end

    def errors(auto, where)
      return [ "#{where}: #{I18n.t('arrange.errors.auto')}" ] unless auto.is_a?(Hash) && (auto.keys - KEYS).empty? &&
                                                                       (auto["area"].is_a?(String) ^ (auto["home"] == true)) &&
                                                                       (!auto.key?("areas") || (auto["areas"].is_a?(Array) && auto["areas"].all?(String)))

      []
    end

    # Congelar: a marca sai; a visão fica como estava (já refeita) e vira normal.
    def freeze_view(defn, site, view_id)
      expanded = expand(defn, site)
      expanded.merge("views" => expanded["views"].map { |v| v["id"] == view_id ? v.except("auto") : v })
    end

    # Visão automática nova de uma área (id único no painel).
    def new_area_view(defn, area)
      ids = Array(defn["views"]).pluck("id")
      base = "auto-#{area.name.parameterize.presence || area.id.first(8)}".first(40)
      id = base
      n = 1
      id = "#{base}-#{n += 1}" while ids.include?(id)
      { "id" => id, "title" => area.name, "icon" => area.icon.presence || "view-boards", "area" => area.id,
        "auto" => { "area" => area.id }, "sections" => [] }
    end
  end
end
