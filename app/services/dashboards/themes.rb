module Dashboards
  # Galeria de temas (uiweb), por registro como os widgets: tema novo = classe
  # que herda de `Base` (aqui ou num arquivo próprio) + nome em `PLUGINS`. O
  # painel e cada visão escolhem no JSON:
  #
  #   "theme": { "key": "aurora", "night": "grafite", "image": "/rails/...", "blur": 12, "glass": true }
  #
  # `night`: o tema da noite; a noite é pelo sol do local (`Sun`, padrão quando o local tem
  # latitude/longitude) ou por janela (`night_by: "window"`, `night_from`/`night_to` "HH:MM",
  # padrão 18:00–06:00; também quando o sol não nasce/não se põe). `image`: papel de parede
  # (enviado no editor ou link), com `blur` (0 a 40 px) e véu do tema;
  # `glass`: cartões de vidro; `dark`: a visão abre no modo escuro, qualquer que seja o da pessoa (papel de
  # parede escuro, como os temas só escuros do HA: no claro, o véu branco por cima deixava tudo cinza). A
  # visão herda do painel e troca o que disser (fundo por cômodo = o tema da visão do cômodo).
  #
  # Fundo por hora do dia (beleza, ideia 15): `backgrounds` = até 6 faixas
  # `{ "from": "HH:MM" | "sunrise" | "sunset", "image" | "color" [+ "color2"] }`; vale a última
  # que já começou hoje (antes da primeira, a última de ontem). `color` sozinha = cor lisa, com
  # `color2` = degradê; `image` troca o papel de parede. `dim` (0 a 80, %): escurece o fundo à noite.
  module Themes
    PLUGINS = %w[Lista Aurora Oceano Floresta PorDoSol Grafite Lavanda Rosa Areia Menta Ceu Cafe CeuNoturno MeiaNoite].freeze
    KEYS = %w[key night image blur glass dark night_by night_from night_to backgrounds dim].freeze
    NIGHT_BY = %w[sun window].freeze
    WINDOW = %w[18:00 06:00].freeze # janela padrão (sem sol)
    BG_COLORS = %w[#1e1b4b #0ea5e9].freeze # cores iniciais do fundo por hora (1ª e 2ª do degradê)
    SUN_EVENTS = %w[sunrise sunset].freeze
    MAX_BACKGROUNDS = 6
    TIME = /\A([01]\d|2[0-3]):[0-5]\d\z/
    IMAGE = %r{\A(https://|/)[^"'()\s<>]+\z}
    HEX = /\A#\h{6}\z/

    module_function

    def plugins = PLUGINS.map { |n| const_get(n) }
    # mobile-ajustes (15/11/2026): só os prontos. Os "temas da casa" (DashboardTheme, chave "u-...") saíram da
    # tela; a chave antiga ainda resolve para painel que não foi migrado (`[]`), mas não entra na galeria.
    def all = plugins
    # Tema pronto mais parecido com uma cor (importação do HA, migração dos temas da casa): o de matiz mais perto.
    def nearest(hex, dark: false)
      return Lista unless hex.to_s.match?(HEX)

      list = plugins.select { |t| t.dark == dark }.presence || plugins
      list.min_by { |t| hue_distance(hue(hex), hue(t.accent)) }
    end

    def hue(hex)
      r, g, b = hex[1..].scan(/../).map { |c| c.hex / 255.0 }
      max, min = [ r, g, b ].max, [ r, g, b ].min
      return 0 if max == min

      d = max - min
      h = if max == r then ((g - b) / d) % 6
      elsif max == g then ((b - r) / d) + 2
      else ((r - g) / d) + 4
      end
      h * 60
    end

    def hue_distance(a, b) = [ (a - b).abs, 360 - (a - b).abs ].min

    def [](key) = plugins.find { |t| t.key == key.to_s } || (DashboardTheme.find_by(key: key.to_s) if key.to_s.start_with?("u-") && ActsAsTenant.current_tenant)

    # Variáveis CSS da marca a partir das duas cores (já validadas): as da gem (ComponentesUi.brand_css, o
    # mesmo SsBrand.fromColors que o app usa no DashThemes.brand) e o papel de parede.
    def css_vars(accent, accent2, wallpaper = nil)
      [ ComponentesUi.brand_css(accent, accent2), ("--ss-wall: #{wallpaper}" if wallpaper) ].compact.join("; ")
    end

    def errors(theme, where)
      return [] if theme.nil?
      return [ I18n.t("dashboards.schema.theme_object", where: where) ] unless theme.is_a?(Hash)

      e = []
      e << I18n.t("dashboards.schema.theme_unknown", where: where) unless (theme.keys - KEYS).empty?
      %w[key night].each { |k| e << I18n.t("dashboards.schema.theme_missing", where: where, theme: theme[k].inspect) if theme.key?(k) && !self[theme[k]] }
      e << I18n.t("dashboards.schema.theme_image", where: where) if theme.key?("image") && !theme["image"].to_s.match?(IMAGE)
      e << I18n.t("dashboards.schema.theme_blur", where: where) if theme.key?("blur") && !(theme["blur"].is_a?(Integer) && theme["blur"].between?(0, 40))
      %w[glass dark].each { |k| e << I18n.t("dashboards.schema.theme_glass", where: where) if theme.key?(k) && ![ true, false ].include?(theme[k]) }
      e << I18n.t("dashboards.schema.theme_night_by", where: where) if theme.key?("night_by") && !NIGHT_BY.include?(theme["night_by"])
      %w[night_from night_to].each { |k| e << I18n.t("dashboards.schema.theme_time", where: where, key: k) if theme.key?(k) && !theme[k].to_s.match?(TIME) }
      e << I18n.t("dashboards.schema.theme_dim", where: where) if theme.key?("dim") && !(theme["dim"].is_a?(Integer) && theme["dim"].between?(0, 80))
      e.concat(background_errors(theme["backgrounds"], where)) if theme.key?("backgrounds")
      e
    end

    def background_errors(list, where)
      return [ I18n.t("dashboards.schema.theme_backgrounds", where: where, max: MAX_BACKGROUNDS) ] unless list.is_a?(Array) && list.size <= MAX_BACKGROUNDS && list.all?(Hash)

      list.flat_map do |b|
        e = []
        e << I18n.t("dashboards.schema.theme_bg_from", where: where) unless b["from"].to_s.match?(TIME) || SUN_EVENTS.include?(b["from"])
        e << I18n.t("dashboards.schema.theme_image", where: where) if b.key?("image") && !b["image"].to_s.match?(IMAGE)
        e << I18n.t("dashboards.schema.theme_bg_color", where: where) if %w[color color2].any? { |k| b.key?(k) && !b[k].to_s.match?(HEX) }
        e << I18n.t("dashboards.schema.theme_bg_empty", where: where) unless b["image"].present? || b["color"].present?
        e
      end
    end

    # É noite no local agora? Pelo sol (padrão com coordenadas) ou pela janela.
    def night?(theme, site, now = Time.current)
      local = now.in_time_zone(site.timezone)
      if theme["night_by"] != "window" && site.latitude.present? && site.longitude.present?
        rise, set = SUN_EVENTS.map { |ev| Sun.at(ev, local.to_date, site.latitude, site.longitude, local.time_zone) }
        return local < rise || local >= set if rise && set
      end
      from = minutes(theme["night_from"] || WINDOW[0])
      to = minutes(theme["night_to"] || WINDOW[1])
      m = (local.hour * 60) + local.min
      from > to ? (m >= from || m < to) : (m >= from && m < to)
    end

    # O fundo da faixa do dia que vale agora (nil sem `backgrounds`).
    def background_now(theme, site, now = Time.current)
      list = Array(theme["backgrounds"]).select { |b| b.is_a?(Hash) }
      return if list.empty?

      local = now.in_time_zone(site.timezone)
      starts = list.filter_map { |b| (m = start_of(b["from"], site, local)) && [ m, b ] }.sort_by(&:first)
      return if starts.empty?

      m = (local.hour * 60) + local.min
      bg = (starts.reverse.find { |(start, _)| start <= m } || starts.last).last
      { "image" => (bg["image"] if bg["image"].to_s.match?(IMAGE)), "color" => (bg["color"] if bg["color"].to_s.match?(HEX)),
        "color2" => (bg["color2"] if bg["color2"].to_s.match?(HEX)) }.compact.presence
    end

    def start_of(from, site, local)
      return minutes(from) if from.to_s.match?(TIME)
      return unless SUN_EVENTS.include?(from) && site.latitude.present? && site.longitude.present?

      at = Sun.at(from, local.to_date, site.latitude, site.longitude, local.time_zone)&.in_time_zone(local.time_zone) or return
      (at.hour * 60) + at.min
    end

    def minutes(hhmm)
      h, m = hhmm.to_s.split(":").map(&:to_i)
      (h.to_i * 60) + m.to_i
    end

    # CSS do fundo da faixa (só cores e link já validados).
    def wall_css(wall)
      return unless wall
      return "linear-gradient(160deg, #{wall['color']}, #{wall['color2']})" if wall["color"] && wall["color2"]

      wall["color"]
    end

    # O tema que vale agora para a visão: painel + visão, e o de noite se for
    # noite no local. ondaB2 (B11): o tema da pessoa (perfil ou aparelho,
    # `Current.theme_key`) vale por cima das cores; o papel de parede enviado fica.
    def resolve(definition, view, site, now: Time.current)
      t = (definition["theme"] || {}).merge(view&.dig("theme") || {})
      mine = Current.theme_key.presence && self[Current.theme_key]
      return nil if t.empty? && !mine

      dark_now = night?(t, site, now)
      # mobile-ajustes: o tema da pessoa vale por inteiro (cores, fundo, vidro e escuro), por cima do desenho do
      # painel; "Seguir o painel" (sem tema escolhido) traz de volta as fotos e o fundo de cada visão.
      return person(mine, dark_now) if mine

      night = t["night"].present? && dark_now
      theme = self[night ? t["night"] : t["key"]] || Lista
      wall = background_now(t, site, now)
      { "theme" => theme, "night" => night, "image" => wall ? wall["image"] : t["image"], "blur" => t["blur"] || 0, "glass" => t.fetch("glass", theme.glass),
        "dark" => t["dark"] == true || theme.dark, "is_night" => dark_now, "wall" => wall&.except("image").presence,
        "dim" => (t["dim"].to_i if dark_now && t["dim"].to_i.positive?) }.compact
    end

    # O tema escolhido pela pessoa (perfil ou aparelho) sozinho, em qualquer tela.
    def person(theme, is_night = false)
      { "theme" => theme, "night" => false, "blur" => 0, "glass" => theme.glass, "dark" => theme.dark, "is_night" => is_night }
    end

    class Base
      extend PluginTexts
      translates :label

      class << self
        attr_reader :key, :accent, :accent2, :wallpaper, :glass, :dark

        # accent/accent2: as duas cores do degradê da marca (botões, ligado,
        # hero); wallpaper: fundo CSS sem imagem; glass: cartões de vidro;
        # dark: o tema só existe no escuro (abre no escuro, qualquer que seja o da pessoa).
        def describe(key:, label:, accent:, accent2:, wallpaper: nil, glass: false, dark: false)
          raise ArgumentError, "cor inválida" unless [ accent, accent2 ].all? { |c| c.match?(HEX) }

          @key = key
          @label = label
          @accent = accent
          @accent2 = accent2
          @wallpaper = wallpaper
          @glass = glass
          @dark = dark
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
      texts en: { label: "Graphite" }, es: { label: "Grafito" }
      describe key: "grafite", label: "Grafite", accent: "#6366f1", accent2: "#0ea5e9", glass: true, dark: true,
               wallpaper: "radial-gradient(80% 60% at 50% -10%, rgba(99, 102, 241, .35), transparent), radial-gradient(50% 40% at 100% 100%, rgba(14, 165, 233, .18), transparent)"
    end

    # mobile-ajustes (15/11/2026): mais temas prontos no lugar dos temas da casa.
    class Lavanda < Base
      texts en: { label: "Lavender" }, es: { label: "Lavanda" }
      describe key: "lavanda", label: "Lavanda", accent: "#7c3aed", accent2: "#c084fc",
               wallpaper: "radial-gradient(65% 55% at 10% 0%, rgba(192, 132, 252, .30), transparent), radial-gradient(55% 55% at 95% 95%, rgba(124, 58, 237, .24), transparent)"
    end

    class Rosa < Base
      texts en: { label: "Rose" }, es: { label: "Rosa" }
      describe key: "rosa", label: "Rosa", accent: "#db2777", accent2: "#fb7185",
               wallpaper: "radial-gradient(65% 55% at 0% 0%, rgba(251, 113, 133, .28), transparent), radial-gradient(55% 55% at 100% 100%, rgba(219, 39, 119, .22), transparent)"
    end

    class Areia < Base
      texts en: { label: "Sand" }, es: { label: "Arena" }
      describe key: "areia", label: "Areia", accent: "#b45309", accent2: "#eab308",
               wallpaper: "radial-gradient(70% 60% at 100% 0%, rgba(234, 179, 8, .24), transparent), radial-gradient(60% 50% at 0% 100%, rgba(180, 83, 9, .20), transparent)"
    end

    class Menta < Base
      texts en: { label: "Mint" }, es: { label: "Menta" }
      describe key: "menta", label: "Menta", accent: "#0d9488", accent2: "#22c55e",
               wallpaper: "radial-gradient(70% 60% at 0% 0%, rgba(45, 212, 191, .26), transparent), radial-gradient(60% 55% at 100% 100%, rgba(34, 197, 94, .22), transparent)"
    end

    class Ceu < Base
      texts en: { label: "Sky" }, es: { label: "Cielo" }
      describe key: "ceu", label: "Céu", accent: "#0284c7", accent2: "#38bdf8", glass: true,
               wallpaper: "radial-gradient(80% 60% at 50% -10%, rgba(56, 189, 248, .32), transparent), radial-gradient(55% 50% at 0% 100%, rgba(2, 132, 199, .20), transparent)"
    end

    class Cafe < Base
      texts en: { label: "Coffee" }, es: { label: "Café" }
      describe key: "cafe", label: "Café", accent: "#92400e", accent2: "#c2410c",
               wallpaper: "radial-gradient(70% 60% at 0% 0%, rgba(194, 65, 12, .22), transparent), radial-gradient(60% 55% at 100% 100%, rgba(146, 64, 14, .22), transparent)"
    end

    # O "Casa-glass" importado do HA (azul, vidro e escuro) virou tema pronto.
    class CeuNoturno < Base
      texts en: { label: "Night sky" }, es: { label: "Cielo nocturno" }
      describe key: "ceu-noturno", label: "Céu noturno", accent: "#5aa9ff", accent2: "#3b82f6", glass: true, dark: true,
               wallpaper: "radial-gradient(80% 60% at 50% -10%, rgba(90, 169, 255, .30), transparent), radial-gradient(50% 45% at 100% 100%, rgba(59, 130, 246, .20), transparent)"
    end

    class MeiaNoite < Base
      texts en: { label: "Midnight" }, es: { label: "Medianoche" }
      describe key: "meia-noite", label: "Meia-noite", accent: "#8b5cf6", accent2: "#22d3ee", glass: true, dark: true,
               wallpaper: "radial-gradient(70% 55% at 0% 0%, rgba(139, 92, 246, .30), transparent), radial-gradient(60% 50% at 100% 100%, rgba(34, 211, 238, .18), transparent)"
    end
  end
end
