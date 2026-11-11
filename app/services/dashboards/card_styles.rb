module Dashboards
  # Galeria de estilos de card (ideia 19 da proposta de personalização):
  # compacto, vidro, foto, minimalista... aplicados ao painel inteiro em um
  # clique (`"card_style": "vidro"` na definição). Cada estilo é dado, um YAML
  # em `config/card_styles/` (estilo novo = um arquivo): os tokens do
  # componentes-ui que a web troca (`web`, só os de `TOKENS`, com valor sem
  # `;{}` nem `url(`) e o que o app aplica (`app`: densidade e superfície). O
  # Resolver devolve `card_style_now` pronto; a web põe os tokens no `<body>`.
  module CardStyles
    DIR = Rails.root.join("config/card_styles")
    TOKENS = %w[--ss-card-bg --ss-card-border --ss-card-filter --ss-card-pad --ss-radius-card --r-card --shadow-card --ss-gap].freeze
    VALUE = /\A[\w\s%().,#+-]{1,120}\z/
    DENSITIES = %w[compact standard comfortable].freeze
    FLAGS = %w[glass flat photo].freeze
    Style = Data.define(:key, :icon, :label, :description, :web, :app)

    module_function

    def all
      @all ||= Dir[DIR.join("*.yml")].map { |f| YAML.safe_load_file(f, aliases: false) }.sort_by { |h| [ h["position"].to_i, h["key"] ] }.filter_map do |h|
        next unless h["key"].to_s.match?(/\A[a-z0-9-]{2,30}\z/)

        web = h["web"].to_h.select { |k, v| TOKENS.include?(k) && v.to_s.match?(VALUE) && !v.to_s.include?("url(") }
        app = h["app"].to_h.slice("density", *FLAGS)
        app["density"] = app["density"].presence_in(DENSITIES) || "standard"
        Style.new(key: h["key"], icon: h["icon"].presence || "color-swatch", label: h["label"], description: h["description"], web: web.freeze, app: app.freeze)
      end.freeze
    end

    def [](key) = all.find { |s| s.key == key.to_s }
    def label(style) = CardTemplates.loc(style.label)
    def description(style) = CardTemplates.loc(style.description)

    def errors(value)
      return [] if value.nil? || value == ""

      self[value] ? [] : [ I18n.t("dashboards.card_styles.unknown", keys: all.map(&:key).join(", ")) ]
    end

    # Tokens CSS do estilo (para o `style` do `<body>`); "" sem estilo.
    def css(key) = (s = self[key]) ? s.web.map { |k, v| "#{k}: #{v}" }.join("; ") : ""

    # O que vai no painel resolvido para o app ({"card_style_now" => {...}}), ou nada.
    def now(key)
      s = self[key] or return {}
      { "card_style_now" => { "key" => s.key, "label" => label(s) }.merge(s.app) }
    end
  end
end
