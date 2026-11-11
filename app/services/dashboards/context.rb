module Dashboards
  # Painel por contexto (ideia 9 da proposta de personalização): condições de
  # sol e presença no `visible_if`/`style_if` de qualquer widget, a ordem das
  # seções de cada visão (`order_if`) e a visão que abre (`open_if`), tudo
  # decidido no servidor (web e app só desenham).
  #
  #   "visible_if": { "sun": { "is": "night" }, "presence": { "home": "anyone" } }
  #   visão:  "order_if": [ { "when": { "presence": { "home": "nobody" } }, "first": ["s-seguranca", "s-cameras"] } ]
  #   painel: "open_if":  [ { "when": { "time": { "after": "22:00", "before": "06:00" } }, "view": "noite" } ]
  #
  # Condição nova = classe em `CONDITIONS` (`key`, `errors(valor)`,
  # `ok?(resolver, valor)`, `refs(resolver, valor)` = pontos do tempo real);
  # o Resolver e o Schema perguntam ao registro (nada de `case` por chave).
  # A ordem e a visão que abre valem ao abrir o painel (como o topo); o
  # `visible_if` também se refaz pelo tempo real.
  module Context
    CONDITIONS = %w[Sun Presence].freeze
    MAX_RULES = 10

    module_function

    def plugins = CONDITIONS.map { |n| const_get(n) }
    def [](key) = plugins.find { |c| c.key == key.to_s }
    def keys = plugins.map(&:key)
    def msg(key, **vars) = I18n.t("dashboards.context.errors.#{key}", **vars)

    # Chave do visible_if que o Resolver não conhece: a condição registrada decide;
    # o que não é dela (papel, tela, aparelho) é da tela ou já saiu antes.
    def ok?(r, key, value)
      c = self[key] or return true
      c.ok?(r, value)
    end

    def refs(r, cond)
      return [] unless cond.is_a?(Hash)

      cond.flat_map { |k, v| (c = self[k]) ? c.refs(r, v) : [] }
    end

    # Erros das condições registradas dentro de um visible_if (sem o "onde").
    def errors(cond)
      return [] unless cond.is_a?(Hash)

      cond.flat_map { |k, v| (c = self[k]) ? c.errors(v) : [] }
    end

    # Regras `[{when, <campo>}]` de `order_if`/`open_if`: `check_when` valida a condição.
    def rule_errors(rules, field, &check_when)
      return [ msg(:rules, max: MAX_RULES) ] unless rules.is_a?(Array) && rules.size.between?(1, MAX_RULES)

      rules.flat_map.with_index(1) do |r, n|
        next [ msg(:rule, n: n) ] unless r.is_a?(Hash) && (r.keys - [ "when", field ]).empty?

        e = []
        e << msg(field == "first" ? :first : :view, n: n) unless valid_target?(r[field], field)
        e.concat(Array(check_when&.call(r["when"], n))) if r.key?("when")
        e
      end
    end

    def valid_target?(value, field)
      return value.is_a?(String) && value.match?(/\A[\w-]{1,100}\z/) if field == "view"

      value.is_a?(Array) && value.size.between?(1, 20) && value.all? { |s| s.is_a?(String) }
    end

    # Seções da visão na ordem da primeira regra `order_if` que bate (as citadas
    # primeiro, na ordem dada; o resto como estava). `order_now` = ids na ordem.
    def arrange(r, view)
      rule = Array(view["order_if"]).find { |o| o.is_a?(Hash) && r.condition?(o["when"]) } or return view

      first = Array(rule["first"])
      sections = Array(view["sections"])
      picked = first.filter_map { |id| sections.find { |s| s["id"] == id } }
      view.merge("sections" => picked + (sections - picked), "order_now" => first & sections.map { |s| s["id"] })
    end

    # A visão que abre agora (id), pela primeira regra `open_if` que bate; nil = a primeira.
    def open_view(r, definition, views)
      Array(definition["open_if"]).each do |o|
        next unless o.is_a?(Hash) && r.condition?(o["when"])

        v = views.find { |x| x["id"] == o["view"] || x["path"] == o["view"] } and return v["id"]
      end
      nil
    end

    # `sun`: `{is: day|night}` ou janela `{after, before}` com `sunrise`/`sunset`
    # (+ `after_offset`/`before_offset` em minutos), no fuso do local. Sem
    # latitude/longitude no local, o dia vai das 6h às 18h.
    class Sun
      EVENTS = %w[sunrise sunset].freeze
      FALLBACK = { "sunrise" => 6, "sunset" => 18 }.freeze

      def self.key = "sun"
      def self.refs(_r, _v) = []

      def self.errors(v)
        ok = v.is_a?(Hash) && (v.keys - %w[is after before after_offset before_offset]).empty? &&
             (v.key?("is") ? %w[day night].include?(v["is"]) && v.keys == [ "is" ] : [ v["after"], v["before"] ].compact.any?) &&
             [ v["after"], v["before"] ].compact.all? { |e| EVENTS.include?(e) } &&
             [ v["after_offset"], v["before_offset"] ].compact.all? { |m| m.is_a?(Integer) && m.abs <= 720 }
        ok ? [] : [ Context.msg(:sun) ]
      end

      def self.ok?(r, v)
        now = Time.current.in_time_zone(r.site.timezone)
        rise = at(r.site, "sunrise", now)
        set = at(r.site, "sunset", now)
        return (now >= rise && now < set) == (v["is"] == "day") if v["is"]

        after = v["after"] ? at(r.site, v["after"], now) + v["after_offset"].to_i.minutes : now.beginning_of_day
        before = v["before"] ? at(r.site, v["before"], now) + v["before_offset"].to_i.minutes : now.end_of_day
        after <= before ? now >= after && now < before : now >= after || now < before
      end

      def self.at(site, event, now)
        t = (::Sun.at(event, now.to_date, site.latitude, site.longitude, now.time_zone) if site.latitude && site.longitude)
        t ? t.in_time_zone(now.time_zone) : now.change(hour: FALLBACK[event])
      end
    end

    # `presence`: `{home: anyone|nobody|everyone}` sobre as pessoas do local
    # (helpers `person`), ou `{person: <ponto>, home: true|false}`. Sem pessoa
    # cadastrada nenhuma regra de presença vale (não se sabe quem está).
    class Presence
      GROUP = %w[anyone nobody everyone].freeze

      def self.key = "presence"

      def self.errors(v)
        ok = v.is_a?(Hash) && (v.keys - %w[home person]).empty? &&
             (v.key?("person") ? v["person"].is_a?(String) && [ true, false ].include?(v["home"]) : GROUP.include?(v["home"]))
        ok ? [] : [ Context.msg(:presence) ]
      end

      def self.persons(r, v)
        list = r.points.select { |p| p.helper == "person" && Points::Query.exists?(p) }
        v["person"] ? [ r.point(v["person"]) ].compact : list
      end

      def self.refs(r, v) = persons(r, v).map(&:id)

      def self.ok?(r, v)
        home = r.memo(:home_zone) { HelperTypes::Zone.home_of(People.zones(r.site))&.name }
        at_home = ->(p) { home.present? && p.value == home }
        people = persons(r, v)
        return people.any? && at_home.call(people.first) == v["home"] if v["person"]

        case v["home"]
        when "anyone" then people.any?(&at_home)
        when "nobody" then people.any? && people.none?(&at_home)
        else people.any? && people.all?(&at_home)
        end
      end
    end
  end
end
