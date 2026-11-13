module Dashboards
  # Operações do editor web sobre uma cópia da definição (o rascunho): criar,
  # alterar, mover (setas) e remover view, seção e widget. Quem chama valida
  # (Schema) e grava; aqui só se mexe no JSON. Levanta KeyError se o id não
  # existe.
  class Editor
    attr_reader :definition

    def initialize(definition)
      @definition = definition.deep_dup
      @definition["schema_version"] ||= Schema::VERSION
      @definition["views"] ||= []
    end

    def add_view(title:, icon: nil)
      views << { "id" => new_id("v"), "title" => title.presence || "Nova view", "icon" => icon.presence, "sections" => [] }.compact
      views.last["id"]
    end

    # `path`: o pedaço da URL da visão (?view=cozinha); vazio = usa o id.
    # ondaB2 (B8): `type` (ViewTypes), subvisão e para onde ela volta.
    def update_view(id, title:, icon: nil, path: nil, type: nil, subview: nil, back_path: nil)
      v = view(id)
      v.merge!("title" => title.presence || v["title"], "icon" => icon.presence, "path" => path.to_s.parameterize.presence,
               "type" => (type if type.present? && type != "sections" && ViewTypes[type]), "subview" => (true if subview == "1"),
               "back_path" => (back_path.presence if subview == "1")).compact!
      %w[type subview back_path].each { |k| v.delete(k) if v[k].nil? }
    end

    # Beleza (ideia 17): a visão que abre primeiro (`start_view`, ex. a planta); desmarcar a atual tira.
    def set_start(id, on)
      view(id)
      if on
        @definition["start_view"] = id
      elsif @definition["start_view"] == id
        @definition.delete("start_view")
      end
    end

    # visao-entrega: papel e tela da visão pelo formulário ("Mostrar em", "Quem vê"); o `device` do JSON fica.
    def set_view_visible(id, attrs)
      v = view(id)
      visible = (v["visible_if"].is_a?(Hash) ? v["visible_if"] : {}).except("role", "screen").merge(attrs.compact)
      visible.present? ? v["visible_if"] = visible : v.delete("visible_if")
    end

    # P1.4: topo da visão (Dashboards::Hero); vazio tira a chave.
    def set_hero(id, hero)
      v = view(id)
      hero.present? ? v["hero"] = hero : v.delete("hero")
    end

    def add_section(view_id, title:)
      sections = view(view_id)["sections"] ||= []
      sections << { "id" => new_id("s"), "title" => title.presence, "widgets" => [] }.compact
      sections.last["id"]
    end

    def update_section(id, title:, span: nil, position: nil)
      s = section(id)
      s["title"] = title.presence
      s["span"] = span
      s["position"] = position.presence_in(%w[sidebar]) # ondaB2: coluna lateral da visão "sidebar"
      s.compact!
    end

    # `target`: a seção ou uma pilha (ondaB2 B8).
    def add_widget(target, attrs)
      w = { "id" => new_id("w") }.merge(attrs)
      holder(target) << w
      w["id"]
    end

    # O formulário só cuida de papel e tela no visible_if: o resto (estado,
    # faixa, OU, hora, vindos do JSON) fica.
    def update_widget(id, attrs)
      w = widget(id)
      visible = (w["visible_if"] || {}).except(*FORM_VISIBILITY).merge(attrs["visible_if"] || {})
      kids = w["widgets"] if Widgets[attrs["type"]]&.container?
      attrs = Widgets[attrs["type"]].keep(w, attrs) if Widgets[attrs["type"]] && w["type"] == attrs["type"]
      w.replace({ "id" => w["id"] }.merge(attrs).merge("visible_if" => visible.presence, "widgets" => kids).compact)
    end

    FORM_VISIBILITY = %w[role screen].freeze

    # kind: view/section/widget; dir: up/down. No limite da lista, não faz nada.
    def move(kind, id, dir)
      list = container(kind, id)
      i = list.index { |x| x["id"] == id }
      j = dir == "up" ? i - 1 : i + 1
      list[i], list[j] = list[j], list[i] if j.between?(0, list.size - 1)
    end

    # Arrastar e soltar (uiweb): leva a seção/widget para a posição `index`
    # (0 = primeiro) da visão/seção `parent` (widget pode trocar de seção; sem
    # parent, fica onde está).
    def place(kind, id, index, parent: nil)
      from = container(kind, id)
      item = from.find { |x| x["id"] == id }
      to = if parent.blank? then from
      elsif kind == "widget" then holder(parent)
      else view(parent)["sections"] ||= []
      end
      from.delete(item)
      to.insert(index.to_i.clamp(0, to.size), item)
    end

    # Alça de largura (uiweb): span de uma tela (1 a 12) do widget ou da seção.
    def resize(kind, id, screen, cols)
      raise KeyError, "tela #{screen}" unless Schema::SCREENS.include?(screen)

      item = kind == "section" ? section(id) : widget(id)
      default = kind == "section" ? { "mobile" => 12, "tablet" => 12, "desktop" => 12 } : { "mobile" => 12, "tablet" => 6, "desktop" => 4 }
      item["span"] = default.merge(item["span"] || {}).merge(screen => cols.to_i.clamp(1, 12))
    end

    # Tema (uiweb) do painel (view_id vazio) ou de uma visão; vazio = herda/padrão.
    def set_theme(view_id, theme)
      target = view_id.present? ? view(view_id) : @definition
      theme = theme.reject { |_, v| v.nil? || v == "" }
      theme.empty? ? target.delete("theme") : target["theme"] = theme
    end

    # P1.5: o JSON de um widget inteiro, editado à mão (o id fica o mesmo; quem chama valida pelo Schema).
    def replace_widget(id, attrs)
      raise ArgumentError, "widget" unless attrs.is_a?(Hash)

      widget(id).replace(attrs.merge("id" => id))
    end

    # Ideia 7 (atalho e Ctrl+K): cópia logo depois do original, com ids novos.
    def duplicate(kind, id)
      list = container(kind, id)
      i = list.index { |x| x["id"] == id }
      list.insert(i + 1, fresh(list[i]))
      list[i + 1]["id"]
    end

    # Ideia 4: o que vai para a área de transferência (cópia solta, sem mexer no painel).
    def item(kind, id) = (kind == "section" ? section(id) : widget(id)).deep_dup

    # Ideia 4: cola um widget numa seção/pilha ou uma seção numa visão (no fim), com ids novos.
    def paste(kind, target, item)
      list = kind == "section" ? (view(target)["sections"] ||= []) : holder(target)
      list << fresh(item)
      list.last["id"]
    end

    # "Colar estilo": só as chaves de aparência do widget copiado (sem elas na cópia, saem do alvo).
    STYLE_KEYS = %w[style_if color icon].freeze

    def paste_style(id, source)
      w = widget(id)
      STYLE_KEYS.each { |k| source.key?(k) ? w[k] = source[k].deep_dup : w.delete(k) }
    end

    def remove(kind, id)
      @definition.delete("start_view") if kind == "view" && @definition["start_view"] == id
      container(kind, id).reject! { |x| x["id"] == id }
    end

    def view(id) = views.find { |v| v["id"] == id } || raise(KeyError, "view #{id}")
    def section(id) = sections.find { |s| s["id"] == id } || raise(KeyError, "seção #{id}")
    def widget(id) = widgets.find { |w| w["id"] == id } || raise(KeyError, "widget #{id}")

    private

    def views = @definition["views"]
    def sections = views.flat_map { |v| Array(v["sections"]) }
    def widgets = Resolver.flatten(sections.flat_map { |s| Array(s["widgets"]) })

    # Lista onde entra um widget: a de uma seção ou a de uma pilha.
    def holder(id)
      s = sections.find { |x| x["id"] == id }
      return s["widgets"] ||= [] if s

      w = widget(id)
      raise KeyError, "seção #{id}" unless Widgets[w["type"]]&.container?

      w["widgets"] ||= []
    end

    def container(kind, id)
      case kind
      when "view" then views
      when "section" then views.find { |v| Array(v["sections"]).any? { |s| s["id"] == id } }&.dig("sections")
      when "widget" then [ *sections, *widgets ].find { |s| Array(s["widgets"]).any? { |w| w["id"] == id } }&.dig("widgets")
      end || raise(KeyError, "#{kind} #{id}")
    end

    # Cópia com ids novos (a seção, seus widgets e os de dentro das pilhas).
    def fresh(item)
      copy = item.deep_dup
      copy["id"] = new_id(copy.key?("type") ? "w" : "s")
      copy["widgets"] = Array(copy["widgets"]).map { |w| fresh(w) } if copy.key?("widgets")
      copy
    end

    def new_id(prefix) = "#{prefix}-#{SecureRandom.alphanumeric(8).downcase}"
  end
end
