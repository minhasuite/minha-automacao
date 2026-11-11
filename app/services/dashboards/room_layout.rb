module Dashboards
  # Arrumação das visões de cômodo (visão `sections`): sensores só de leitura
  # viram selos no topo (`badges` da visão, a linha inteira acima das seções)
  # e o resto vai para colunas (até 4; o padrão tem 3), na ordem em que estavam:
  #
  #   1 `actions` — o que se comanda (interruptor, luz, tomada, dimmer,
  #     cortina, portão, clima, ponto gravável);
  #   2 `scenes`  — cenas (`scene_bar`) e automações (ponto de automação,
  #     `AutomationPoints`, e script); a barra de cena ocupa a coluna toda
  #     fora do celular (uma embaixo da outra);
  #   3 `media`   — câmera, mídia, gráfico e medidas que não são selo.
  #
  # Regra: dado (`Dashboards::Arrange`, P2.1): as colunas, o que vira selo e
  # o ícone do selo vêm das regras do painel (`definition["arrange"]`), do
  # local (Configurações → Painéis → Arrumação) ou do padrão
  # (`Arrange::DEFAULT`, as tabelas de antes). Título (`heading`) vai para a coluna do primeiro widget dele
  # que não virou selo; os outros do grupo que caem em outra coluna entram no
  # fim do grupo em curso dela (sem título repetido); sem widget (todos
  # viraram selo), o título sai. Coluna vazia não entra; a largura divide a
  # linha (3 = 4/4/4 e 2 = 6/6 no computador, 6/6/12 no tablet; coluna única
  # = metade da linha; 12 no celular, na ordem selos e colunas).
  # Selo de ponto que a visão já mostra no topo não se repete. Rodar de novo no resultado
  # não muda nada. Não comanda nada: só devolve a definição nova.
  class RoomLayout
    FULL = { "mobile" => 12, "tablet" => 12, "desktop" => 12 }.freeze

    # Uma visão arrumada: [visão nova, relatório {coluna => [nomes]}].
    def self.view(view, site, rules: nil) = new(site, rules: rules).view(view)

    # Arruma as visões de cômodo (as que têm `area`) do painel publicado. Sem
    # `publish`, só escreve o antes → depois; com ele, publica uma versão
    # nova (`Dashboard#publish!`, volta pelo histórico de versões).
    def self.apply!(dashboard, publish: false, author: nil, io: $stdout)
      defn = dashboard.published.deep_dup
      layout = new(dashboard.site, rules: Arrange.rules(dashboard.site, defn))
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

    attr_reader :rules

    def initialize(site, rules: nil)
      @points = site.points.includes(:device).to_a
      @by_id = @points.index_by(&:id)
      @by_key = @points.index_by(&:key)
      @rules = rules || Arrange.rules(site)
      @columns = Array(@rules["columns"])
      @badges = @rules["badges"].to_h
      @query = Points::Query.new(site, points: @points)
    end

    def view(view)
      return [ view, {} ] unless ViewTypes.for(view) == ViewTypes::Sections

      ids = ids_of(view)
      badges = Array(view["badges"]).map(&:dup)
      cols = @columns.to_h { |c| [ c["id"], [] ] }
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
          cols[col] << (full?(col, w) ? w.merge("span" => FULL.merge("mobile" => w.dig("span", "mobile") || 12)) : w)
          report[col] << label(w)
        end
      end
      used = @columns.select { |c| cols[c["id"]].any? }
      sections = used.each_with_index.map do |c, i|
        old = Array(view["sections"])[i] || {}
        { "id" => old["id"] || unique("#{view['id']}-#{c['id']}", ids), "span" => span(i, used.size), "widgets" => cols[c["id"]],
          "title" => c["title"].presence }.compact.merge(old.slice("title", "icon").compact)
      end
      [ view.merge("badges" => badges, "sections" => sections.presence || [ { "id" => unique("#{view['id']}-s", ids), "widgets" => [] } ]), report ]
    end

    # Coluna do widget (id da coluna) ou :badge. Ordem: tipo do widget numa coluna; pilha/grade = a do primeiro de
    # dentro; sem ponto = reserva; selo; consulta de uma coluna (na ordem); reserva.
    def column(w)
      by_type = @columns.find { |c| Array(c["match"]).any? { |m| Array(m["type"]).include?(w["type"]) } } and return by_type["id"]
      # Pilha/grade nunca vira selo (antes: quebrava no `to_badge` sem ponto).
      return column(w["widgets"].first).then { _1 == :badge ? fallback : _1 } if w["widgets"].is_a?(Array) && w["widgets"].any?

      p = point(w["bind"]) or return fallback
      return :badge if badge?(w, p)

      @columns.find { |c| Array(c["match"]).any? { |m| m["query"].present? && @query.match?(p, m["query"]) } }&.dig("id") || fallback
    end

    def badge?(w, p) = Array(@badges["widgets"]).include?(w["type"]) && Array(@badges["match"]).any? { |m| m["query"].present? && @query.match?(p, m["query"]) }

    private

    def point(ref) = ref.is_a?(String) ? (@by_id[ref] || @by_key[ref]) : nil
    def label(w) = w["name"].presence || w["label"].presence || w["title"].presence || point(w["bind"])&.name || w["type"]

    # Selo `stat` do mesmo ponto (o valor agora), com o nome e o ícone do tile.
    def to_badge(w)
      p = point(w["bind"])
      icons = @badges["icons"].to_h
      icon = w["icon"].presence || p.icon.to_s[/\Amdi:.+/] || icons[p.device_class.to_s] || icons[p.capability]
      { "id" => w["id"], "type" => "stat", "bind" => w["bind"], "label" => label(w), "icon" => icon, "aggregate" => "last",
        "visible_if" => w["visible_if"] }.compact
    end

    # Já há selo do mesmo ponto mostrando o valor (sem atributo).
    def dup_badge?(badges, w) = badges.any? { |b| b["type"] == "stat" && b["bind"] == w["bind"] && b["attribute"].blank? }

    def fallback
      ids = @columns.pluck("id")
      ids.include?(@rules["fallback"]) ? @rules["fallback"] : ids.last
    end
    def full?(col, w) = Array(@columns.find { |c| c["id"] == col }&.dig("full")).include?(w["type"])

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
