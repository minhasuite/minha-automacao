module Dashboards
  # Tipos de visão (ondaB2 B8; masonry, panel, sidebar e sections do HA), por
  # registro: tipo novo = classe que herda de `Base` + nome em `PLUGINS` +
  # partial `web/dashboards/views/_<chave>`. No JSON da visão:
  #
  #   { "id": "v2", "title": "Câmeras", "type": "panel", "subview": true, "back_path": "inicio", "sections": [...] }
  #
  # A visão guarda sempre seções e widgets (o editor e o tempo real não
  # mudam); o tipo só muda o desenho. `subview`: fora das abas, com "voltar"
  # para `back_path` (caminho ou id; sem ele, a primeira visão).
  module ViewTypes
    PLUGINS = %w[Sections Masonry Panel Sidebar].freeze
    POSITIONS = %w[main sidebar].freeze
    BACK = %r{\A(?:[\w-]{1,100}|/paineis/[\w-]{1,40}(?:\?view=[\w-]{1,40})?)\z}

    module_function

    def plugins = PLUGINS.map { |n| const_get(n) }
    def [](key) = plugins.find { |t| t.key == key.to_s }
    def for(view) = self[view["type"].presence || "sections"] || Sections

    def errors(view, where)
      e = []
      e << I18n.t("dashboards.schema.view_type", where: where) if view.key?("type") && !self[view["type"]]
      e << I18n.t("dashboards.schema.view_subview", where: where) if view.key?("subview") && ![ true, false ].include?(view["subview"])
      e << I18n.t("dashboards.schema.view_back", where: where) if view.key?("back_path") && !view["back_path"].to_s.match?(BACK)
      Array(view["sections"]).each do |s|
        e << I18n.t("dashboards.schema.section_position", where: where) if s.is_a?(Hash) && s.key?("position") && !POSITIONS.include?(s["position"])
      end
      e.concat(self.for(view).errors(view).map { |m| "#{where}: #{m}" })
    end

    # Visões das abas: as subvisões só aparecem quando abertas.
    def tabs(views, current) = views.reject { |v| v["subview"] == true && v != current }

    # Para onde o "voltar" da subvisão leva. `back_path` também pode ser outro
    # painel (`/paineis/<id>?view=<caminho>`, painel importado do HA): `other`.
    def back(views, view)
      return unless view["subview"] == true
      return other(view["back_path"]) if view["back_path"].to_s.start_with?("/")

      ref = view["back_path"]
      views.find { |v| ref && (v["path"] == ref || v["id"] == ref) } || views.find { |v| v["subview"] != true }
    end

    def other(path)
      id = path.to_s[%r{\A/paineis/([\w-]+)}, 1]
      d = id && Dashboard.find_by(id: id) or return nil
      { "title" => d.name, "href" => path }
    end

    class Base
      extend PluginTexts
      translates :label, :description

      class << self
        attr_reader :key, :icon

        def describe(key:, label:, icon:, description:)
          @key = key
          @label = label
          @icon = icon
          @description = description
        end

        def partial = "web/dashboards/views/#{key}"
        def errors(_view) = []
      end
    end

    class Sections < Base
      describe key: "sections", label: "Seções", icon: "view-boards", description: "Grade de 12 colunas com seções lado a lado (o padrão)."
      texts en: { label: "Sections", description: "12-column grid with sections side by side (the default)." },
            es: { label: "Secciones", description: "Cuadrícula de 12 columnas con secciones lado a lado (lo predeterminado)." }
    end

    class Masonry < Base
      describe key: "masonry", label: "Mosaico", icon: "view-grid", description: "Os cards em colunas que se encaixam pela altura, sem seções."
      texts en: { label: "Masonry", description: "Cards in columns packed by height, no sections." },
            es: { label: "Mosaico", description: "Las tarjetas en columnas encajadas por altura, sin secciones." }
    end

    class Panel < Base
      describe key: "panel", label: "Painel inteiro", icon: "arrows-expand", description: "Um card só ocupando a tela (mapa, planta, câmera)."
      texts en: { label: "Panel", description: "A single card filling the screen (map, floor plan, camera)." },
            es: { label: "Panel completo", description: "Una sola tarjeta ocupando la pantalla (mapa, plano, cámara)." }
    end

    class Sidebar < Base
      describe key: "sidebar", label: "Com barra lateral", icon: "template", description: "Coluna principal larga e uma coluna lateral (as seções marcadas)."
      texts en: { label: "Sidebar", description: "A wide main column and a side column (the marked sections)." },
            es: { label: "Con barra lateral", description: "Columna principal ancha y una columna lateral (las secciones marcadas)." }
    end
  end
end
