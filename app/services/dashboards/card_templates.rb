module Dashboards
  # Modelos de card declarativos (P1.3 da proposta de personalização): card
  # novo sem classe Ruby, partial nem widget Dart. Um modelo é dado:
  #
  #   { "key" => "area", "name" => "Cartão de área", "layout" => "mosaic",
  #     "params" => [ { "key" => "area", "label" => "Área", "kind" => "area", "required" => true } ],
  #     "slots" => { "title" => "{{ vars.area.name }}", "facts" => { "from" => "area_defaults", "scope" => { "area" => "{{ vars.area }}" } },
  #                  "tone" => [ { "when" => { "state" => { "point" => "{{ vars.porta }}", "is" => "true" } }, "value" => "danger" } ],
  #                  "tap" => { "action" => "navigate", "navigation_path" => "{{ vars.area.link }}" } } }
  #
  # `layout`: só os desenhos que existem no componentes-ui e no app (LAYOUTS).
  # Espaços de texto (title, subtitle, icon, image, value): texto Liquid (o
  # sandbox das automações, com limite; `vars.<entrada>` com nome/texto/valor),
  # consulta + conta (`{query, aggregate, format, label}`, o mesmo item do
  # `Dashboards::Facts`) ou regras (`[{when, value}]`, a condição do
  # `visible_if`/`style_if`; a primeira que bate). `facts`: itens do
  # `Dashboards::Facts` (lista, ou `{items|from, scope}`). `tone`: token, regras
  # ou consulta com `tone` (vale quando o número não é zero). `tap`: só uma ação
  # do `Dashboards::Actions` (o widget nunca comanda direto).
  #
  # Nos espaços de dado (consultas, regras, tap), `{{ vars.x }}` vira o id
  # escolhido no widget (`Placeholders`); `{{ vars.area.link }}` o caminho da
  # área. Modelos embutidos em `config/card_templates/*.yml` (o cartão de área
  # é um deles, que a pessoa duplica e edita); os do local na tabela
  # `card_templates` (mesma chave = o do local vale).
  module CardTemplates
    LAYOUTS = %w[mosaic tile row chip stat].freeze
    TEXT_SLOTS = %w[title subtitle icon image value].freeze
    SLOTS = (TEXT_SLOTS + %w[facts tone tap]).freeze
    KINDS = %w[area point text number].freeze
    KEY = /\A[a-z0-9][a-z0-9_-]{1,39}\z/
    PARAM = /\A[a-z][a-z0-9_]{0,29}\z/
    MAX_PARAMS = 8
    MAX_TEXT = 300
    MAX_RULES = 10
    # Itens prontos que o espaço `facts` pode pedir por nome (`{"from": "area_defaults"}`).
    FACT_SOURCES = { "area_defaults" => ->(site) { Facts.area_defaults(site) } }.freeze
    DIR = Rails.root.join("config/card_templates")

    module_function

    def msg(key, **vars) = I18n.t("dashboards.templates.errors.#{key}", **vars)

    # Texto que pode vir por idioma ({"pt-BR" => ..., "en" => ...}) nos embutidos.
    def loc(v)
      return v.to_s unless v.is_a?(Hash)

      (v[I18n.locale.to_s] || v["pt-BR"] || v.values.first).to_s
    end

    # Embutidos (config/card_templates/*.yml), lidos uma vez.
    def builtins
      @builtins ||= Dir[DIR.join("*.yml")].sort.map do |f|
        YAML.safe_load_file(f, aliases: false).merge("builtin" => true, "version" => 1).freeze
      end.freeze
    end

    def builtin(key) = builtins.find { |t| t["key"] == key.to_s }

    # O modelo do local com a chave, ou o embutido; nil = não existe.
    def find(site, key)
      return nil unless key.to_s.match?(KEY)

      site.card_templates.find_by(key: key)&.to_template || builtin(key)
    end

    # Todos para escolher (os do local primeiro; embutido com a chave tomada some).
    def all(site)
      own = site.card_templates.order(:name).map(&:to_template)
      own + builtins.reject { |b| own.any? { |t| t["key"] == b["key"] } }
    end

    def name(t) = loc(t["name"])
    def param_label(p) = loc(p["label"]).presence || p["key"]

    # ---- validação -------------------------------------------------------

    def errors(t)
      return [ msg(:object) ] unless t.is_a?(Hash)

      e = []
      e << msg(:key) unless t["key"].to_s.match?(KEY)
      e << msg(:name) if name(t).strip.empty?
      e << msg(:layout, layouts: LAYOUTS.join(", ")) unless LAYOUTS.include?(t["layout"])
      e.concat(param_errors(t["params"]))
      slots = t["slots"]
      return e << msg(:slots) unless slots.is_a?(Hash)

      e << msg(:slot_unknown, slots: SLOTS.join(", ")) unless (slots.keys - SLOTS).empty?
      known = Array(t["params"]).filter_map { |p| p["key"] if p.is_a?(Hash) }
      unknown = Placeholders.names(slots, "vars") - known
      e << msg(:var_unknown, vars: unknown.join(", ")) if unknown.any?
      TEXT_SLOTS.each { |s| e.concat(text_errors(slots[s], s)) if slots.key?(s) }
      e.concat(facts_errors(slots["facts"])) if slots.key?("facts")
      e.concat(text_errors(slots["tone"], "tone", tone: true)) if slots.key?("tone")
      e.concat(tap_errors(slots["tap"], known)) if slots.key?("tap")
      e
    end

    def param_errors(params)
      return [ msg(:params, max: MAX_PARAMS) ] unless params.is_a?(Array) && params.size <= MAX_PARAMS

      keys = []
      params.flat_map.with_index(1) do |p, n|
        next [ msg(:param, n: n) ] unless p.is_a?(Hash) && p["key"].to_s.match?(PARAM) && !keys.include?(p["key"])

        keys << p["key"]
        KINDS.include?(p["kind"]) ? [] : [ msg(:param_kind, n: n, kinds: KINDS.join(", ")) ]
      end
    end

    def text_errors(v, slot, tone: false)
      case v
      when String
        return [ msg(:text, slot: slot, max: MAX_TEXT) ] if v.size > MAX_TEXT

        Liquid::Template.parse(v, error_mode: :strict)
        tone && !v.include?("{") && !Facts::TONES.include?(v.strip) ? [ msg(:tone, slot: slot, tones: Facts::TONES.join(", ")) ] : []
      when Hash
        e = Facts.errors([ { "id" => "v" }.merge(v.except("tone")) ]).map { |m| "#{slot}: #{m}" }
        e << msg(:tone, slot: slot, tones: Facts::TONES.join(", ")) if tone && !Facts::TONES.include?(v["tone"])
        e
      when Array
        return [ msg(:rules, slot: slot, max: MAX_RULES) ] unless v.size.between?(1, MAX_RULES) && v.all?(Hash)

        v.flat_map.with_index(1) do |r, n|
          sub = []
          Schema.visible_if(r["when"], "#{slot} #{n}", sub) if r.key?("when")
          sub << msg(:rule_value, slot: slot, n: n) unless r["value"].is_a?(String) && r["value"].size <= MAX_TEXT
          sub << msg(:tone, slot: slot, tones: Facts::TONES.join(", ")) if tone && r["value"].is_a?(String) && !r["value"].include?("{") && !Facts::TONES.include?(r["value"])
          sub
        end
      else [ msg(:slot_kind, slot: slot) ]
      end
    rescue Liquid::Error => ex
      [ msg(:liquid, slot: slot, error: ex.message.truncate(120)) ]
    end

    def facts_errors(v)
      items, scope = facts_parts(v)
      return [ msg(:facts) ] if items.nil?

      e = items.is_a?(Array) ? Facts.errors(items) : []
      e << msg(:facts) if scope && !(scope.is_a?(Hash) && (scope.keys - Points::Query::KEYS).empty?)
      e.map { |m| "facts: #{m}" }
    end

    # Ação só do registro (Dashboards::Actions), com as entradas trocadas por um valor de exemplo.
    def tap_errors(tap, known)
      return [ msg(:tap) ] unless tap.is_a?(Hash)

      sample = Placeholders.fill(tap, "vars") { |path| known.include?(path.split(".").first) ? "sample" : nil }
      Actions.errors({ "tap_action" => sample })
    end

    # Espaço `facts` → [lista ou nome da fonte, escopo]; nil = formato errado.
    def facts_parts(v)
      return [ v, nil ] if v.is_a?(Array)
      return [ nil, nil ] unless v.is_a?(Hash) && (v.keys - %w[items from scope]).empty?
      return [ v["from"], v["scope"] ] if v["from"].is_a?(String) && FACT_SOURCES.key?(v["from"])

      [ v["items"].is_a?(Array) ? v["items"] : nil, v["scope"] ]
    end

    # ---- resolver --------------------------------------------------------

    # [data, pontos de que depende] do modelo com as entradas do widget. `widget`: o widget
    # (para o caminho da lista de cada item; nil na prévia do editor).
    def render(r, t, vars, widget: nil)
      return [ { "missing" => true, "template" => widget&.dig("template") }, [] ] unless t

      ctx = Render.new(r, t, vars.is_a?(Hash) ? vars : {}, widget)
      [ ctx.data, ctx.deps ]
    end

    # Pontos que entram no item `key` (a lista do toque, ideia 14).
    def drill(r, t, vars, key)
      Render.new(r, t, vars.is_a?(Hash) ? vars : {}, nil).drill(key)
    end

    class Render
      def deps = @deps.compact.uniq

      def initialize(r, t, vars, widget)
        @r = r
        @t = t
        @widget = widget
        @deps = []
        @raw = {}
        @expanded = {}
        @points = []
        Array(t["params"]).each { |p| bind(p, vars[p["key"]]) }
        @slots = t["slots"].to_h
      end

      def data
        out = { "template" => @t["key"], "layout" => @t["layout"], "version" => @t["version"] }
        TEXT_SLOTS.each { |s| out[s] = text(@slots[s]) if @slots.key?(s) }
        out["tone"] = tone(@slots["tone"]) if @slots.key?("tone")
        out["facts"] = facts if @slots.key?("facts")
        out["tap"] = tap if @slots.key?("tap")
        out["missing_vars"] = missing.presence
        out["variant"] = variant
        out.compact_blank.merge("facts" => out["facts"]).compact
      end

      def drill(key)
        items, scope = parts
        fact = Array(items).find { |f| f["id"] == key } or return nil
        points = Facts.points(@r, fact, scope: scope)
        { "title" => Facts.one(fact, points, nil)&.dig("text") || text(@slots["title"]).to_s, "subtitle" => text(@slots["title"]), "points" => points }
      end

      private

      # Entrada escolhida no widget: o id (área/ponto) para os espaços de dado, e
      # o objeto que o Liquid vê (`vars.area.name`, `vars.luz.text`).
      def bind(p, value)
        key = p["key"]
        case p["kind"]
        when "area"
          area = (@r.area(value) if value.present?) or return
          view = Array(@r.definition["views"]).find { |v| v["area"] == area.id }
          count = @r.query({ "area" => area.id }).size
          @raw[key] = area.id
          @expanded[key] = { "id" => area.id, "name" => area.name, "icon" => area.icon, "background" => area.background, "points" => count,
                             "caption" => I18n.t("dashboards.ed.points", count: count),
                             "link" => view ? view["path"].presence || view["id"] : Rails.application.routes.url_helpers.area_path(area) }
        when "point"
          point = @r.use(@r.point(value.to_s)) or return
          @deps << point
          @points << point
          @raw[key] = point.id
          @expanded[key] = (@drops ||= Automations::Context.new(site: @r.site)).point_drop(point).merge("id" => point.id)
        when "number"
          n = Widgets::Base.number(value)
          @raw[key] = @expanded[key] = n unless n.nil?
        else
          @raw[key] = @expanded[key] = value.to_s.first(MAX_TEXT) if value.present?
        end
      end

      def missing = Array(@t["params"]).select { |p| p["required"] && !@raw.key?(p["key"]) }.map { |p| CardTemplates.param_label(p) }

      # Depois de ler as entradas (o Context copia as variáveis ao nascer).
      def liquid = @liquid ||= Automations::Context.new(site: @r.site, vars: @expanded)

      # Espaço de dado com as entradas: `{{ vars.x }}` = id; `{{ vars.x.y }}` = o campo da entrada.
      def filled(obj)
        Placeholders.fill(obj, "vars") do |path|
          head, *rest = path.split(".")
          rest.empty? ? @raw[head] : @expanded[head].is_a?(Hash) ? @expanded[head].dig(*rest) : nil
        end
      end

      def text(spec)
        case spec
        when String then render_liquid(spec)
        when Hash then query_value(filled(spec))&.dig("text")
        when Array then (rule = rule(spec)) && render_liquid(rule["value"].to_s)
        end
      end

      def tone(spec)
        v = case spec
        when Hash then (f = query_value(filled(spec))) && Facts.present?(f["value"]) ? spec["tone"] : nil
        else text(spec)
        end
        v.to_s.strip.presence_in(Facts::TONES)
      end

      def render_liquid(s)
        return s.presence unless s.include?("{{") || s.include?("{%")

        @expanded.each_value { |v| @deps << @r.point(v["id"]) if v.is_a?(Hash) && v.key?("key") }
        liquid.render(s, limit: MAX_TEXT).strip.presence
      rescue Automations::Context::Error
        nil
      end

      def query_value(f)
        q = f["query"].to_h
        @deps.concat(@r.query(q, with_state: false))
        Facts.one({ "id" => "v", "show" => "always" }.merge(f), @r.query(q), nil)
      end

      def rule(rules)
        list = filled(rules)
        list.each { |rl| @r.condition_refs(rl["when"]).each { |ref| @deps << @r.use(@r.point(ref)) } }
        list.find { |rl| @r.condition?(rl["when"]) }
      end

      def parts
        items, scope = CardTemplates.facts_parts(@slots["facts"])
        items = FACT_SOURCES[items].call(@r.site) if items.is_a?(String)
        [ items, filled(scope.to_h) ]
      end

      def facts
        items, scope = parts
        return [] if items.nil? || (scope.values.any?(&:nil?))

        url = @widget && @r.dashboard&.persisted? ? ->(id) { Widgets::Base.drill_url(@r, @widget, id) } : nil
        list, deps = Facts.resolve(@r, items, scope: scope, url: url)
        @deps.concat(deps)
        list
      end

      def tap
        action = filled(@slots["tap"])
        return nil if action.blank? || missing.any?

        Actions.resolve(@r, { "tap_action" => action }, @points.first(1))["tap"]
      end

      # Tom do bloco do mosaico (0 a 4): a mesma conta do cartão de área (soma dos códigos do id da área).
      def variant
        seed = @raw.values.find { |v| v.is_a?(String) } || @t["key"]
        seed.to_s.bytes.sum % 5
      end
    end
  end
end
