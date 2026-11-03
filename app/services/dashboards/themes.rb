module Dashboards
  # Galeria de temas (uiweb), por registro como os widgets: tema novo = classe
  # que herda de `Base` (aqui ou num arquivo próprio) + nome em `PLUGINS`. O
  # painel e cada visão escolhem no JSON:
  #
  #   "theme": { "key": "aurora", "night": "grafite", "image": "/rails/...", "blur": 12, "glass": true }
  #
  # `night`: o tema das 18h às 6h (fuso do local); `image`: papel de parede
  # (enviado no editor ou link), com `blur` (0 a 40 px) e véu do tema;
  # `glass`: cartões de vidro. A visão herda do painel e troca o que disser.
  module Themes
    PLUGINS = %w[Lista Aurora Oceano Floresta PorDoSol Grafite].freeze
    KEYS = %w[key night image blur glass].freeze
    NIGHT = (18..23).to_a + (0..5).to_a
    IMAGE = %r{\A(https://|/)[^"'()\s<>]+\z}
    HEX = /\A#\h{6}\z/

    module_function

    def plugins = PLUGINS.map { |n| const_get(n) }
    # ondaB2 (B11): os prontos e os da casa (DashboardTheme, chave "u-...").
    def all = plugins + (ActsAsTenant.current_tenant ? DashboardTheme.order(:name).to_a : [])
    def [](key) = plugins.find { |t| t.key == key.to_s } || (DashboardTheme.find_by(key: key.to_s) if key.to_s.start_with?("u-") && ActsAsTenant.current_tenant)

    # Variáveis CSS da marca a partir das duas cores (já validadas).
    def css_vars(accent, accent2, wallpaper = nil)
      [ "--accent: #{accent}", "--accent-solid: #{accent}", "--accent-hover: #{accent}", "--accent2: #{accent2}", "--accent-soft: color-mix(in srgb, #{accent} 14%, var(--surface))",
        "--grad: linear-gradient(135deg, #{accent} 0%, #{accent2} 100%)", "--glow: color-mix(in srgb, #{accent} 16%, transparent)", "--ring: color-mix(in srgb, #{accent} 22%, transparent)",
        ("--wall: #{wallpaper}" if wallpaper) ].compact.join("; ")
    end

    def errors(theme, where)
      return [] if theme.nil?
      return [ I18n.t("dashboards.schema.theme_object", where: where) ] unless theme.is_a?(Hash)

      e = []
      e << I18n.t("dashboards.schema.theme_unknown", where: where) unless (theme.keys - KEYS).empty?
      %w[key night].each { |k| e << I18n.t("dashboards.schema.theme_missing", where: where, theme: theme[k].inspect) if theme.key?(k) && !self[theme[k]] }
      e << I18n.t("dashboards.schema.theme_image", where: where) if theme.key?("image") && !theme["image"].to_s.match?(IMAGE)
      e << I18n.t("dashboards.schema.theme_blur", where: where) if theme.key?("blur") && !(theme["blur"].is_a?(Integer) && theme["blur"].between?(0, 40))
      e << I18n.t("dashboards.schema.theme_glass", where: where) if theme.key?("glass") && ![ true, false ].include?(theme["glass"])
      e
    end

    # O tema que vale agora para a visão: painel + visão, e o de noite se for
    # noite no local. ondaB2 (B11): o tema da pessoa (perfil ou aparelho,
    # `Current.theme_key`) vale por cima das cores; o papel de parede enviado fica.
    def resolve(definition, view, site, now: Time.current)
      t = (definition["theme"] || {}).merge(view&.dig("theme") || {})
      mine = Current.theme_key.presence && self[Current.theme_key]
      return nil if t.empty? && !mine

      night = !mine && t["night"].present? && NIGHT.include?(now.in_time_zone(site.timezone).hour)
      theme = mine || self[night ? t["night"] : t["key"]] || Lista
      { "theme" => theme, "night" => night, "image" => t["image"], "blur" => t["blur"] || 0, "glass" => t.fetch("glass", theme.glass) }
    end

    class Base
      extend PluginTexts
      translates :label

      class << self
        attr_reader :key, :accent, :accent2, :wallpaper, :glass

        # accent/accent2: as duas cores do degradê da marca (botões, ligado,
        # hero); wallpaper: fundo CSS sem imagem; glass: cartões de vidro.
        def describe(key:, label:, accent:, accent2:, wallpaper: nil, glass: false)
          raise ArgumentError, "cor inválida" unless [ accent, accent2 ].all? { |c| c.match?(HEX) }

          @key = key
          @label = label
          @accent = accent
          @accent2 = accent2
          @wallpaper = wallpaper
          @glass = glass
        end

        # Variáveis CSS do tema (só cores validadas na definição).
        def css = Themes.css_vars(accent, accent2, wallpaper)
      end
    end

    class Lista < Base
      describe key: "lista", label: "Lista Clara", accent: "#5a45e8", accent2: "#3b82f6"
      texts en: { label: "Lista Clara" }, es: { label: "Lista Clara" }
    end

    class Aurora < Base
      texts en: { label: "Aurora" }, es: { label: "Aurora" }
      describe key: "aurora", label: "Aurora", accent: "#7c3aed", accent2: "#ec4899", glass: true,
               wallpaper: "radial-gradient(60% 50% at 15% 10%, rgba(236, 72, 153, .35), transparent), radial-gradient(50% 60% at 90% 30%, rgba(124, 58, 237, .4), transparent), radial-gradient(60% 50% at 50% 100%, rgba(59, 130, 246, .3), transparent)"
    end

    class Oceano < Base
      texts en: { label: "Ocean" }, es: { label: "Océano" }
      describe key: "oceano", label: "Oceano", accent: "#0284c7", accent2: "#14b8a6",
               wallpaper: "radial-gradient(70% 60% at 0% 0%, rgba(14, 165, 233, .28), transparent), radial-gradient(60% 60% at 100% 100%, rgba(20, 184, 166, .28), transparent)"
    end

    class Floresta < Base
      texts en: { label: "Forest" }, es: { label: "Bosque" }
      describe key: "floresta", label: "Floresta", accent: "#059669", accent2: "#65a30d",
               wallpaper: "radial-gradient(70% 60% at 100% 0%, rgba(16, 185, 129, .25), transparent), radial-gradient(60% 50% at 0% 100%, rgba(101, 163, 13, .22), transparent)"
    end

    class PorDoSol < Base
      texts en: { label: "Sunset" }, es: { label: "Atardecer" }
      describe key: "por-do-sol", label: "Pôr do sol", accent: "#ea580c", accent2: "#db2777", glass: true,
               wallpaper: "radial-gradient(70% 60% at 10% 0%, rgba(251, 146, 60, .35), transparent), radial-gradient(60% 60% at 95% 90%, rgba(219, 39, 119, .3), transparent)"
    end

    class Grafite < Base
      texts en: { label: "Graphite (night)" }, es: { label: "Grafito (noche)" }
      describe key: "grafite", label: "Grafite (noite)", accent: "#6366f1", accent2: "#0ea5e9", glass: true,
               wallpaper: "radial-gradient(80% 60% at 50% -10%, rgba(99, 102, 241, .35), transparent), radial-gradient(50% 40% at 100% 100%, rgba(14, 165, 233, .18), transparent)"
    end
  end
end
