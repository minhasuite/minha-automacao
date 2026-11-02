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
    def update_view(id, title:, icon: nil, path: nil)
      view(id).merge!("title" => title.presence || view(id)["title"], "icon" => icon.presence,
                      "path" => path.to_s.parameterize.presence).compact!
    end

    def add_section(view_id, title:)
      sections = view(view_id)["sections"] ||= []
      sections << { "id" => new_id("s"), "title" => title.presence, "widgets" => [] }.compact
      sections.last["id"]
    end

    def update_section(id, title:, span: nil)
      s = section(id)
      s["title"] = title.presence
      s["span"] = span
      s.compact!
    end

    def add_widget(section_id, attrs)
      w = { "id" => new_id("w") }.merge(attrs)
      (section(section_id)["widgets"] ||= []) << w
      w["id"]
    end

    # O formulário só cuida de papel e tela no visible_if: o resto (estado,
    # faixa, OU, hora, vindos do JSON) fica.
    def update_widget(id, attrs)
      w = widget(id)
      visible = (w["visible_if"] || {}).except(*FORM_VISIBILITY).merge(attrs["visible_if"] || {})
      w.replace({ "id" => w["id"] }.merge(attrs).merge("visible_if" => visible.presence).compact)
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
      elsif kind == "widget" then section(parent)["widgets"] ||= []
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

    def remove(kind, id)
      container(kind, id).reject! { |x| x["id"] == id }
    end

    def view(id) = views.find { |v| v["id"] == id } || raise(KeyError, "view #{id}")
    def section(id) = sections.find { |s| s["id"] == id } || raise(KeyError, "seção #{id}")
    def widget(id) = widgets.find { |w| w["id"] == id } || raise(KeyError, "widget #{id}")

    private

    def views = @definition["views"]
    def sections = views.flat_map { |v| Array(v["sections"]) }
    def widgets = sections.flat_map { |s| Array(s["widgets"]) }

    def container(kind, id)
      case kind
      when "view" then views
      when "section" then views.find { |v| Array(v["sections"]).any? { |s| s["id"] == id } }&.dig("sections")
      when "widget" then sections.find { |s| Array(s["widgets"]).any? { |w| w["id"] == id } }&.dig("widgets")
      end || raise(KeyError, "#{kind} #{id}")
    end

    def new_id(prefix) = "#{prefix}-#{SecureRandom.alphanumeric(8).downcase}"
  end
end
