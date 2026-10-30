module Dashboards
  # Validação do JSON do dashboard (ESQUEMA-V1 §6.1, documentado em
  # docs/dashboards.md). Devolve a lista de erros em português; vazia = válido.
  # Feita à mão (sem gem de JSON Schema): o formato é pequeno e as mensagens
  # vão direto para o editor.
  module Schema
    VERSION = 1
    MAX_BYTES = 256.kilobytes
    MAX_WIDGETS = 400

    # Tipo → props obrigatórias. Os da §6.2 de mídia e os da indústria ficam
    # de fora por ora.
    WIDGETS = {
      "heading" => %w[title], "markdown" => %w[text], "tile" => %w[bind], "group" => %w[binds],
      "stat" => [], "gauge" => %w[bind], "chart" => %w[binds], "query_list" => %w[query],
      "area_card" => %w[area], "scene_bar" => [], "alerts" => [], "camera" => %w[bind], "vacuum" => %w[bind]
    }.freeze
    WIDGET_LABELS = {
      "tile" => "Ponto", "group" => "Grupo de pontos", "stat" => "Contador / número", "gauge" => "Medidor",
      "chart" => "Gráfico", "query_list" => "Lista automática", "area_card" => "Área", "scene_bar" => "Cenas",
      "alerts" => "Alertas ativos", "camera" => "Câmera", "vacuum" => "Robô aspirador", "heading" => "Título", "markdown" => "Texto"
    }.freeze
    SCREENS = %w[mobile tablet desktop].freeze
    TAPS = %w[toggle more_info navigate none].freeze
    FEATURES = %w[toggle select slider].freeze
    AGGREGATES = %w[count sum avg min max last].freeze
    RANGES = %w[24h 7d 30d].freeze
    COLORS = %w[accent amber green red blue].freeze
    QUERY_KEYS = %w[capability state tag area quality device_class].freeze
    STATES = %w[on off].freeze
    TIME = /\A([01]\d|2[0-3]):[0-5]\d\z/

    module_function

    def errors(defn)
      e = []
      return [ "precisa ser um objeto JSON" ] unless defn.is_a?(Hash)
      return [ "passa do tamanho máximo (256 KB)" ] if defn.to_json.bytesize > MAX_BYTES

      e << "schema_version precisa ser #{VERSION}" unless defn["schema_version"] == VERSION
      views = defn["views"]
      return e << "views precisa ser uma lista com ao menos uma view" unless views.is_a?(Array) && views.any?

      ids = []
      paths = []
      views.each_with_index do |view, vi|
        next e << "view #{vi + 1} precisa ser um objeto" unless view.is_a?(Hash)

        where = "view #{view['id'] || vi + 1}"
        check_id(view, where, ids, e)
        e << "#{where}: título obrigatório" if view["title"].to_s.strip.empty?
        path(view, where, paths, e)
        Array(view["badges"]).each { |b| widget(b, "#{where} (selo)", ids, e) }
        sections = view["sections"]
        next e << "#{where}: sections precisa ser uma lista" unless sections.is_a?(Array)

        sections.each_with_index do |section, si|
          next e << "#{where}: seção #{si + 1} precisa ser um objeto" unless section.is_a?(Hash)

          swhere = "seção #{section['id'] || si + 1}"
          check_id(section, swhere, ids, e)
          span(section["span"], swhere, e)
          widgets = section["widgets"]
          next e << "#{swhere}: widgets precisa ser uma lista" unless widgets.is_a?(Array)

          widgets.each { |w| widget(w, swhere, ids, e) }
        end
      end
      e << "widgets demais (máximo #{MAX_WIDGETS})" if ids.size > MAX_WIDGETS
      e
    end

    def widget(w, where, ids, e)
      return e << "#{where}: widget precisa ser um objeto" unless w.is_a?(Hash)

      where = "widget #{w['id'] || '?'} (#{where})"
      check_id(w, where, ids, e)
      type = w["type"]
      return e << "#{where}: tipo desconhecido #{type.inspect}" unless WIDGETS.key?(type)

      WIDGETS[type].each { |prop| e << "#{where}: #{prop} obrigatório" if blank?(w[prop]) }
      e << "#{where}: bind precisa ser texto" if w.key?("bind") && !w["bind"].is_a?(String)
      e << "#{where}: binds precisa ser uma lista de até 8 pontos" if w.key?("binds") && !(w["binds"].is_a?(Array) && w["binds"].size <= 8 && w["binds"].all?(String))
      span(w["span"], where, e)
      visible_if(w["visible_if"], where, e)
      query(w["query"], where, e) if w.key?("query")
      e << "#{where}: tap inválido" if w.key?("tap") && !TAPS.include?(w["tap"])
      e << "#{where}: features inválidas" if w.key?("features") && !(w["features"].is_a?(Array) && (w["features"] - FEATURES).empty?)
      e << "#{where}: aggregate inválido" if w.key?("aggregate") && !AGGREGATES.include?(w["aggregate"])
      e << "#{where}: range inválido" if w.key?("range") && !RANGES.include?(w["range"])
      e << "#{where}: color inválida" if w.key?("color") && !COLORS.include?(w["color"])
      e << "#{where}: stat precisa de bind ou query" if type == "stat" && blank?(w["bind"]) && blank?(w["query"])
      e << "#{where}: live precisa ser true ou false" if w.key?("live") && ![ true, false ].include?(w["live"])
      e << "#{where}: snapshot_interval precisa ser de 2 a 300 segundos" if w.key?("snapshot_interval") && !(w["snapshot_interval"].is_a?(Integer) && w["snapshot_interval"].between?(2, 300))
      %w[min max].each { |k| e << "#{where}: #{k} precisa ser número" if w.key?(k) && !w[k].is_a?(Numeric) }
    end

    # Caminho da visão (opcional): minúsculas, números e hífen; único no painel.
    def path(view, where, paths, e)
      return unless view.key?("path")
      return e << "#{where}: caminho só com letras minúsculas, números e hífen (até 40)" unless view["path"].is_a?(String) && view["path"].match?(/\A[a-z0-9][a-z0-9-]{0,39}\z/)

      e << "#{where}: caminho repetido" if paths.include?(view["path"])
      paths << view["path"]
    end

    def check_id(obj, where, ids, e)
      id = obj["id"]
      return e << "#{where}: id obrigatório (texto)" unless id.is_a?(String) && id.match?(/\A[\w-]{1,100}\z/)

      e << "#{where}: id repetido" if ids.include?(id)
      ids << id
    end

    def span(value, where, e)
      return if value.nil?
      return e << "#{where}: span precisa ser {mobile, tablet, desktop}" unless value.is_a?(Hash) && (value.keys - SCREENS).empty?

      value.each { |k, n| e << "#{where}: span.#{k} precisa ser de 1 a 12" unless n.is_a?(Integer) && n.between?(1, 12) }
    end

    def visible_if(value, where, e)
      return if value.nil?
      return e << "#{where}: visible_if precisa ser um objeto" unless value.is_a?(Hash)

      e << "#{where}: visible_if com chave desconhecida" unless (value.keys - %w[role state quality time device]).empty?
      e << "#{where}: visible_if.role inválido" if value.key?("role") && !(value["role"].is_a?(Array) && (value["role"] - SiteMembership::ROLES).empty?)
      e << "#{where}: visible_if.state precisa de {point, is}" if value.key?("state") && !(value["state"].is_a?(Hash) && value["state"]["point"].is_a?(String) && value["state"].key?("is"))
      e << "#{where}: visible_if.quality inválido" if value.key?("quality") && !(Array(value["quality"]) - Point::QUALITIES).empty?
      e << "#{where}: visible_if.device precisa ser lista" if value.key?("device") && !value["device"].is_a?(Array)
      return unless value.key?("time")

      t = value["time"]
      e << "#{where}: visible_if.time precisa de {after, before} em HH:MM" unless t.is_a?(Hash) && [ t["after"], t["before"] ].compact.any? && [ t["after"], t["before"] ].compact.all? { |s| s.to_s.match?(TIME) }
    end

    def query(value, where, e)
      return e << "#{where}: query precisa ser um objeto" unless value.is_a?(Hash)

      e << "#{where}: query com chave desconhecida" unless (value.keys - QUERY_KEYS).empty?
      e << "#{where}: query.capability desconhecida" if value.key?("capability") && !(Array(value["capability"]) - Point::CAPABILITIES.keys).empty?
      e << "#{where}: query.state precisa ser on ou off" if value.key?("state") && !STATES.include?(value["state"])
    end

    def blank?(v) = v.nil? || v == "" || v == [] || v == {}
  end
end
