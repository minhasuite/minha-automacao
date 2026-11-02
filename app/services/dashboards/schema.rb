module Dashboards
  # Validação do JSON do dashboard (ESQUEMA-V1 §6.1, documentado em
  # docs/dashboards.md). Devolve a lista de erros em português; vazia = válido.
  # Feita à mão (sem gem de JSON Schema): o formato é pequeno e as mensagens
  # vão direto para o editor.
  module Schema
    VERSION = 1
    MAX_BYTES = 256.kilobytes
    MAX_WIDGETS = 400

    SCREENS = %w[mobile tablet desktop].freeze
    TAPS = %w[toggle more_info navigate none].freeze
    FEATURES = %w[toggle select slider].freeze
    AGGREGATES = %w[count sum avg min max last].freeze
    RANGES = %w[24h 7d 30d].freeze
    COLORS = %w[accent amber green red blue].freeze
    QUERY_KEYS = Points::Query::KEYS
    STATES = %w[on off].freeze
    # visible_if (Lote 4, G18b: faixa numérica, OU e tamanho de tela). Dentro do
    # `any` (OU) não entram papel nem tela.
    VISIBILITY = %w[role state numeric quality time device screen any].freeze
    MAX_ANY = 10
    TIME = /\A([01]\d|2[0-3]):[0-5]\d\z/

    module_function

    # Mensagem de validação no idioma da tela.
    def msg(key, **vars) = I18n.t("dashboards.schema.#{key}", **vars)

    # Tipo → props obrigatórias e tipo → nome: só do registro (`Dashboards::Widgets`).
    def types = Widgets.plugins.to_h { |p| [ p.type, p.required ] }
    def labels = Widgets.plugins.to_h { |p| [ p.type, p.label ] }

    def errors(defn)
      e = []
      return [ msg(:json_object) ] unless defn.is_a?(Hash)
      return [ msg(:too_big) ] if defn.to_json.bytesize > MAX_BYTES

      e << msg(:schema_version, version: VERSION) unless defn["schema_version"] == VERSION
      views = defn["views"]
      return e << msg(:views_list) unless views.is_a?(Array) && views.any?

      e.concat(Themes.errors(defn["theme"], msg(:at_dashboard)))
      ids = []
      paths = []
      boxes = 0 # visões e seções: dividem os ids, mas não contam no limite de widgets
      views.each_with_index do |view, vi|
        next e << msg(:view_object, n: vi + 1) unless view.is_a?(Hash)

        where = msg(:at_view, id: view['id'] || vi + 1)
        check_id(view, where, ids, e)
        boxes += 1
        e << msg(:title_required, where: where) if view["title"].to_s.strip.empty?
        path(view, where, paths, e)
        e.concat(Themes.errors(view["theme"], where))
        Array(view["badges"]).each { |b| widget(b, msg(:at_badge, where: where), ids, e) }
        sections = view["sections"]
        next e << msg(:sections_list, where: where) unless sections.is_a?(Array)

        sections.each_with_index do |section, si|
          next e << msg(:section_object, where: where, n: si + 1) unless section.is_a?(Hash)

          swhere = msg(:at_section, id: section['id'] || si + 1)
          check_id(section, swhere, ids, e)
          boxes += 1
          span(section["span"], swhere, e)
          widgets = section["widgets"]
          next e << msg(:widgets_list, where: swhere) unless widgets.is_a?(Array)

          widgets.each { |w| widget(w, swhere, ids, e) }
        end
      end
      e << msg(:too_many, max: MAX_WIDGETS) if ids.size - boxes > MAX_WIDGETS
      e
    end

    def widget(w, where, ids, e)
      return e << msg(:widget_object, where: where) unless w.is_a?(Hash)

      where = msg(:at_widget, id: w['id'] || '?', where: where)
      check_id(w, where, ids, e)
      type = w["type"]
      required = types[type] or return e << msg(:unknown_type, where: where, type: type.inspect)

      required.each { |prop| e << msg(:required, where: where, prop: prop) if blank?(w[prop]) }
      e << msg(:bind_text, where: where) if w.key?("bind") && !w["bind"].is_a?(String)
      e << msg(:binds_list, where: where) if w.key?("binds") && !(w["binds"].is_a?(Array) && w["binds"].size <= 8 && w["binds"].all?(String))
      span(w["span"], where, e)
      visible_if(w["visible_if"], where, e)
      query(w["query"], where, e) if w.key?("query")
      e << msg(:bad_tap, where: where) if w.key?("tap") && !TAPS.include?(w["tap"])
      e << msg(:bad_features, where: where) if w.key?("features") && !(w["features"].is_a?(Array) && (w["features"] - FEATURES).empty?)
      e << msg(:bad_aggregate, where: where) if w.key?("aggregate") && !AGGREGATES.include?(w["aggregate"])
      e << msg(:bad_range, where: where) if w.key?("range") && !RANGES.include?(w["range"])
      e << msg(:bad_color, where: where) if w.key?("color") && !COLORS.include?(w["color"])
      e << msg(:live_bool, where: where) if w.key?("live") && ![ true, false ].include?(w["live"])
      e << msg(:snapshot_interval, where: where) if w.key?("snapshot_interval") && !(w["snapshot_interval"].is_a?(Integer) && w["snapshot_interval"].between?(2, 300))
      %w[min max].each { |k| e << msg(:number, where: where, prop: k) if w.key?(k) && !w[k].is_a?(Numeric) }
      Widgets[type].errors(w).each { |m| e << "#{where}: #{m}" }
    end

    # Caminho da visão (opcional): minúsculas, números e hífen; único no painel.
    def path(view, where, paths, e)
      return unless view.key?("path")
      return e << msg(:bad_path, where: where) unless view["path"].is_a?(String) && view["path"].match?(/\A[a-z0-9][a-z0-9-]{0,39}\z/)

      e << msg(:dup_path, where: where) if paths.include?(view["path"])
      paths << view["path"]
    end

    def check_id(obj, where, ids, e)
      id = obj["id"]
      return e << msg(:id_required, where: where) unless id.is_a?(String) && id.match?(/\A[\w-]{1,100}\z/)

      e << msg(:dup_id, where: where) if ids.include?(id)
      ids << id
    end

    def span(value, where, e)
      return if value.nil?
      return e << msg(:span_object, where: where) unless value.is_a?(Hash) && (value.keys - SCREENS).empty?

      value.each { |k, n| e << msg(:span_range, where: where, screen: k) unless n.is_a?(Integer) && n.between?(1, 12) }
    end

    def visible_if(value, where, e, nested: false)
      return if value.nil?
      return e << msg(:visible_object, where: where) unless value.is_a?(Hash)

      e << msg(:visible_unknown, where: where) unless (value.keys - VISIBILITY).empty?
      e << msg(:visible_any_nested, where: where) if nested && (value.key?("role") || value.key?("screen"))
      numeric = value["numeric"]
      e << msg(:visible_numeric, where: where) if value.key?("numeric") &&
                                                                                 !(numeric.is_a?(Hash) && numeric["point"].is_a?(String) && (numeric.keys - %w[point above below]).empty? &&
                                                                                   %w[above below].any? { |k| numeric.key?(k) } && numeric.values_at("above", "below").compact.all?(Numeric))
      e << msg(:visible_screen, where: where, screens: SCREENS.join(', ')) if value.key?("screen") && !(value["screen"].is_a?(Array) && value["screen"].any? && (value["screen"] - SCREENS).empty?)
      if value.key?("any")
        list = value["any"]
        next_level = list.is_a?(Array) && list.size.between?(1, MAX_ANY) && !nested
        e << msg(:visible_any, where: where, max: MAX_ANY) unless next_level
        list.each { |c| visible_if(c, where, e, nested: true) } if next_level
      end
      e << msg(:visible_role, where: where) if value.key?("role") && !(value["role"].is_a?(Array) && (value["role"] - SiteMembership::ROLES).empty?)
      e << msg(:visible_state, where: where) if value.key?("state") && !(value["state"].is_a?(Hash) && value["state"]["point"].is_a?(String) && value["state"].key?("is"))
      e << msg(:visible_quality, where: where) if value.key?("quality") && !(Array(value["quality"]) - Point::QUALITIES).empty?
      e << msg(:visible_device, where: where) if value.key?("device") && !value["device"].is_a?(Array)
      return unless value.key?("time")

      t = value["time"]
      e << msg(:visible_time, where: where) unless t.is_a?(Hash) && [ t["after"], t["before"] ].compact.any? && [ t["after"], t["before"] ].compact.all? { |s| s.to_s.match?(TIME) }
    end

    def query(value, where, e)
      return e << msg(:query_object, where: where) unless value.is_a?(Hash)

      e << msg(:query_unknown, where: where) unless (value.keys - QUERY_KEYS).empty?
      e << msg(:query_capability, where: where) if value.key?("capability") && !(Array(value["capability"]) - Point::CAPABILITIES.keys).empty?
      e << msg(:query_state, where: where) if value.key?("state") && !STATES.include?(value["state"])
    end

    def blank?(v) = v.nil? || v == "" || v == [] || v == {}
  end
end
