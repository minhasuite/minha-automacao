module Dashboards
  # Arrumação das visões de cômodo (visão `sections`): sensores só de leitura
  # viram selos no topo (`badges` da visão, a linha inteira acima das seções)
  # e o resto vai para até 3 colunas, na ordem em que estavam:
  #
  #   1 `actions` — o que se comanda (interruptor, luz, tomada, dimmer,
  #     cortina, portão, clima, ponto gravável);
  #   2 `scenes`  — cenas (`scene_bar`) e automações (ponto de automação,
  #     `AutomationPoints`, e script); a barra de cena ocupa a coluna toda
  #     fora do celular (uma embaixo da outra);
  #   3 `media`   — câmera, mídia, gráfico e medidas que não são selo.
  #
  # Regra (nesta ordem, a primeira que vale): `TYPE_COLUMN` pelo tipo do
  # widget; senão pelo ponto do `bind` (`point_column`); widget sem ponto vai
  # para `media`. Título (`heading`) vai para a coluna do primeiro widget dele
  # que não virou selo; os outros do grupo que caem em outra coluna entram no
  # fim do grupo em curso dela (sem título repetido); sem widget (todos
  # viraram selo), o título sai. Coluna vazia não entra; a largura divide a
  # linha (3 = 4/4/4 e 2 = 6/6 no computador, 6/6/12 no tablet; coluna única
  # = metade da linha; 12 no celular, na ordem selos, ações, cenas, mídia).
  # Selo de ponto que a visão já mostra no topo não se repete. Rodar de novo no resultado
  # não muda nada. Não comanda nada: só devolve a definição nova.
  class RoomLayout
    COLUMNS = %i[actions scenes media].freeze
    # Tipo de widget com coluna fixa (não depende do ponto).
    TYPE_COLUMN = {
      "scene_bar" => :scenes,
      "camera" => :media, "media" => :media, "chart" => :media, "gauge" => :media, "weather" => :media,
      "energy" => :media, "energy_flow" => :media, "energy_breakdown" => :media, "energy_compare" => :media,
      "logbook" => :media, "map" => :media, "image" => :media, "iframe" => :media, "plant" => :media,
      "thermostat" => :actions, "light" => :actions, "humidifier" => :actions, "vacuum" => :actions,
      "remote" => :actions, "alarm" => :actions, "button" => :actions
    }.freeze
    # Ponto de mídia/câmera vai para a coluna 3 mesmo gravável (Echo, TV).
    MEDIA_CAPABILITIES = %w[speaker media stream].freeze
    # Sensor de estado só de leitura que vira selo: por capacidade ou por classe.
    BADGE_CAPABILITIES = %w[contact motion tamper problem].freeze
    BADGE_DEVICE_CLASSES = %w[door window opening garage_door gate motion occupancy presence moisture leak smoke gas
                              battery battery_low problem tamper vibration safety lock].freeze
    # Widgets que viram selo (um ponto, sem desenho próprio).
    BADGEABLE = %w[tile stat].freeze
    # Ícone do selo quando o tile não tinha (pela classe, senão pela capacidade).
    BADGE_ICONS = {
      "door" => "mdi:door", "window" => "mdi:window-closed-variant", "opening" => "mdi:door", "garage_door" => "mdi:garage",
      "gate" => "mdi:gate", "motion" => "mdi:motion-sensor", "occupancy" => "mdi:account", "presence" => "mdi:account",
      "moisture" => "mdi:water-alert", "leak" => "mdi:water-alert", "smoke" => "mdi:smoke-detector", "gas" => "mdi:gas-cylinder",
      "battery" => "mdi:battery-alert", "battery_low" => "mdi:battery-alert", "problem" => "mdi:alert-circle-outline",
      "tamper" => "mdi:shield-alert-outline", "vibration" => "mdi:vibrate", "contact" => "mdi:door"
    }.freeze
    FULL = { "mobile" => 12, "tablet" => 12, "desktop" => 12 }.freeze

    # Uma visão arrumada: [visão nova, relatório {coluna => [nomes]}].
    def self.view(view, site) = new(site).view(view)

    # Arruma as visões de cômodo (as que têm `area`) do painel publicado. Sem
    # `publish`, só escreve o antes → depois; com ele, publica uma versão
    # nova (`Dashboard#publish!`, volta pelo histórico de versões).
    def self.apply!(dashboard, publish: false, author: nil, io: $stdout)
      layout = new(dashboard.site)
      defn = dashboard.published.deep_dup
      defn["views"] = defn["views"].map do |v|
        next v if v["area"].blank?

        after, report = layout.view(v)
        io.puts layout.describe(v, after, report)
        after
      end
      errors = Schema.errors(defn)
      raise ArgumentError, errors.first(5).join("; ") if errors.any?
      return defn if !publish || defn == dashboard.published

      dashboard.publish!(defn, author: author)
      io.puts "publicado: versão #{dashboard.version}"
      defn
    end

    # Antes → depois de uma visão, para conferir antes de publicar.
    def describe(before, after, report)
      cols = ->(v) { Array(v["sections"]).map { |s| "#{s['id']}(#{s.dig('span', 'desktop')}): #{s['widgets'].map { label(_1) }.join(', ')}" } }
      [ "== #{before['id']} (#{before['title']})",
        "  antes  selos: #{Array(before['badges']).map { label(_1) }.join(', ')}", *cols.(before).map { "  antes  #{_1}" },
        "  depois selos: #{Array(after['badges']).map { label(_1) }.join(', ')}", *cols.(after).map { "  depois #{_1}" },
        ("  selo já existia (tile saiu): #{report[:badge_dup].join(', ')}" if report[:badge_dup].present?) ].compact.join("\n")
    end

    def initialize(site)
      @points = site.points.to_a
      @by_id = @points.index_by(&:id)
      @by_key = @points.index_by(&:key)
    end

    def view(view)
      return [ view, {} ] unless ViewTypes.for(view) == ViewTypes::Sections

      ids = ids_of(view)
      badges = Array(view["badges"]).map(&:dup)
      cols = COLUMNS.index_with { [] }
      report = Hash.new { |h, k| h[k] = [] }
      Array(view["sections"]).each do |section|
        heading = nil
        Array(section["widgets"]).each do |w|
          next heading = w if w["type"] == "heading"

          col = column(w)
          if col == :badge
            next report[:badge_dup] << label(w) if dup_badge?(badges, w)

            badges << to_badge(w)
            next report[:badge] << label(w)
          end
          # O título vai junto do primeiro widget dele que fica; os outros entram no grupo em curso da coluna deles.
          cols[col] << heading if heading
          heading = nil
          cols[col] << (col == :scenes && w["type"] == "scene_bar" ? w.merge("span" => FULL.merge("mobile" => w.dig("span", "mobile") || 12)) : w)
          report[col] << label(w)
        end
      end
      used = COLUMNS.select { |c| cols[c].any? }
      sections = used.each_with_index.map do |c, i|
        old = Array(view["sections"])[i] || {}
        { "id" => old["id"] || unique("#{view['id']}-#{c}", ids), "span" => span(i, used.size), "widgets" => cols[c] }
          .merge(old.slice("title", "icon").compact)
      end
      [ view.merge("badges" => badges, "sections" => sections.presence || [ { "id" => unique("#{view['id']}-s", ids), "widgets" => [] } ]), report ]
    end

    # Coluna do widget: :actions, :scenes, :media ou :badge.
    def column(w)
      return TYPE_COLUMN[w["type"]] if TYPE_COLUMN.key?(w["type"])
      return column(w["widgets"].first) || :actions if w["widgets"].is_a?(Array) && w["widgets"].any?

      p = point(w["bind"]) or return :media
      col = point_column(p)
      col == :badge && !BADGEABLE.include?(w["type"]) ? :media : col
    end

    def point_column(p)
      return :scenes if AutomationPoints.automation?(p) || p.capability == "script"
      return :media if MEDIA_CAPABILITIES.include?(p.capability)
      return :badge if badge_point?(p)
      return :actions if p.writable && !Point::READ_ONLY.include?(p.capability)

      :media
    end

    def badge_point?(p)
      return false if p.writable && !Point::READ_ONLY.include?(p.capability)

      BADGE_CAPABILITIES.include?(p.capability) || BADGE_DEVICE_CLASSES.include?(p.device_class.to_s)
    end

    private

    def point(ref) = ref.is_a?(String) ? (@by_id[ref] || @by_key[ref]) : nil
    def label(w) = w["name"].presence || w["label"].presence || w["title"].presence || point(w["bind"])&.name || w["type"]

    # Selo `stat` do mesmo ponto (o valor agora), com o nome e o ícone do tile.
    def to_badge(w)
      p = point(w["bind"])
      icon = w["icon"].presence || p.icon.to_s[/\Amdi:.+/] || BADGE_ICONS[p.device_class.to_s] || BADGE_ICONS[p.capability]
      { "id" => w["id"], "type" => "stat", "bind" => w["bind"], "label" => label(w), "icon" => icon, "aggregate" => "last",
        "visible_if" => w["visible_if"] }.compact
    end

    # Já há selo do mesmo ponto mostrando o valor (sem atributo).
    def dup_badge?(badges, w) = badges.any? { |b| b["type"] == "stat" && b["bind"] == w["bind"] && b["attribute"].blank? }

    def span(i, n)
      tablet = n == 1 || (n.odd? && i == n - 1) ? 12 : 6
      { "mobile" => 12, "tablet" => tablet, "desktop" => n == 1 ? 6 : 12 / n }
    end

    def unique(base, ids)
      id = base
      n = 1
      id = "#{base}-#{n += 1}" while ids.include?(id)
      ids << id
      id
    end

    def ids_of(view)
      [ view["id"], *Array(view["badges"]).map { _1["id"] },
        *Array(view["sections"]).flat_map { |s| [ s["id"], *Resolver.flatten(Array(s["widgets"])).map { _1["id"] } ] } ].compact
    end
  end
end
