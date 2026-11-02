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
    def [](key) = plugins.find { |t| t.key == key.to_s }

    def errors(theme, where)
      return [] if theme.nil?
      return [ "#{where}: theme precisa ser um objeto" ] unless theme.is_a?(Hash)

      e = []
      e << "#{where}: theme com chave desconhecida" unless (theme.keys - KEYS).empty?
      %w[key night].each { |k| e << "#{where}: tema #{theme[k].inspect} não existe" if theme.key?(k) && !self[theme[k]] }
      e << "#{where}: papel de parede precisa ser um link https:// ou /" if theme.key?("image") && !theme["image"].to_s.match?(IMAGE)
      e << "#{where}: blur precisa ser de 0 a 40" if theme.key?("blur") && !(theme["blur"].is_a?(Integer) && theme["blur"].between?(0, 40))
      e << "#{where}: glass precisa ser true ou false" if theme.key?("glass") && ![ true, false ].include?(theme["glass"])
      e
    end

    # O tema que vale agora para a visão: painel + visão, e o de noite se for noite no local.
    def resolve(definition, view, site, now: Time.current)
      t = (definition["theme"] || {}).merge(view&.dig("theme") || {})
      return nil if t.empty?

      night = t["night"].present? && NIGHT.include?(now.in_time_zone(site.timezone).hour)
      theme = self[night ? t["night"] : t["key"]] || Lista
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
        def css
          [ "--accent: #{accent}", "--accent-solid: #{accent}", "--accent-hover: #{accent}", "--accent-soft: color-mix(in srgb, #{accent} 14%, var(--surface))",
            "--grad: linear-gradient(135deg, #{accent} 0%, #{accent2} 100%)", "--glow: color-mix(in srgb, #{accent} 16%, transparent)", "--ring: color-mix(in srgb, #{accent} 22%, transparent)",
            ("--wall: #{wallpaper}" if wallpaper) ].compact.join("; ")
        end
      end
    end

    class Lista < Base
      describe key: "lista", label: "Lista Clara", accent: "#5a45e8", accent2: "#3b82f6"
    end

    class Aurora < Base
      describe key: "aurora", label: "Aurora", accent: "#7c3aed", accent2: "#ec4899", glass: true,
               wallpaper: "radial-gradient(60% 50% at 15% 10%, rgba(236, 72, 153, .35), transparent), radial-gradient(50% 60% at 90% 30%, rgba(124, 58, 237, .4), transparent), radial-gradient(60% 50% at 50% 100%, rgba(59, 130, 246, .3), transparent)"
    end

    class Oceano < Base
      describe key: "oceano", label: "Oceano", accent: "#0284c7", accent2: "#14b8a6",
               wallpaper: "radial-gradient(70% 60% at 0% 0%, rgba(14, 165, 233, .28), transparent), radial-gradient(60% 60% at 100% 100%, rgba(20, 184, 166, .28), transparent)"
    end

    class Floresta < Base
      describe key: "floresta", label: "Floresta", accent: "#059669", accent2: "#65a30d",
               wallpaper: "radial-gradient(70% 60% at 100% 0%, rgba(16, 185, 129, .25), transparent), radial-gradient(60% 50% at 0% 100%, rgba(101, 163, 13, .22), transparent)"
    end

    class PorDoSol < Base
      describe key: "por-do-sol", label: "Pôr do sol", accent: "#ea580c", accent2: "#db2777", glass: true,
               wallpaper: "radial-gradient(70% 60% at 10% 0%, rgba(251, 146, 60, .35), transparent), radial-gradient(60% 60% at 95% 90%, rgba(219, 39, 119, .3), transparent)"
    end

    class Grafite < Base
      describe key: "grafite", label: "Grafite (noite)", accent: "#6366f1", accent2: "#0ea5e9", glass: true,
               wallpaper: "radial-gradient(80% 60% at 50% -10%, rgba(99, 102, 241, .35), transparent), radial-gradient(50% 40% at 100% 100%, rgba(14, 165, 233, .18), transparent)"
    end
  end
end
