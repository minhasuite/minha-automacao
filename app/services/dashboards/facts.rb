module Dashboards
  # Itens do cartão como consultas (P1.1 da proposta de personalização): cada
  # item (`fact`) é um dado, não uma regra no código.
  #
  #   { "id" => "on", "label" => { "zero" => "...", "one" => "%{count} ligado", "other" => "%{count} ligados" },
  #     "icon" => "light-bulb", "query" => { "capability" => "onoff", "state" => "on" },
  #     "aggregate" => "count", "show" => "nonzero", "tone" => "warn", "format" => "W" }
  #
  # `label`: texto (com `%{count}`) ou {zero, one, other}; `label_key` = texto
  # da casa em `dashboards.facts.<chave>` (o padrão nasce assim, nos 3
  # idiomas). `aggregate`: count (padrão), sum/avg/min/max (só leitura boa,
  # como o `stat`) ou any (sim/não). `show`: nonzero (padrão: some com 0/nada)
  # ou always. `tone`: ok/warn/danger/info. `format`: unidade depois do número
  # (sem ela, a do primeiro ponto). O servidor devolve o fato pronto (`text`,
  # `icon`, `tone`, `value`, `count`, `num`, `url`): a web e o app só desenham.
  #
  # Quem usa: `area_card` (o padrão do local em Configurações → Painéis →
  # Padrões, ou `facts` no próprio widget, com `area` injetada na consulta) e,
  # adiante, os modelos de card (P1.3): `resolve(r, facts, scope:)` não sabe
  # de área nenhuma.
  module Facts
    AGGREGATES = %w[count sum avg min max any].freeze
    SHOWS = %w[nonzero always].freeze
    TONES = %w[ok warn danger info].freeze
    MAX = 8
    LABEL_FORMS = %w[zero one other].freeze
    ID = /\A[a-z0-9_-]{1,40}\z/
    # Campos de cada linha do formulário (strong params).
    FORM_FIELDS = [ :id, :label_key, :icon, :aggregate, :show, :tone, :format, :remove, :query_text, { label: LABEL_FORMS, query: Points::Query::KEYS } ].freeze
    # O que os campos do `widget_forms/_query` mostram sem perder nada; o resto vai no texto da consulta.
    FORM_SINGLE = { "capability" => -> { Point::CAPABILITY_LABELS.keys }, "state" => -> { Schema::STATES },
                    "device_class" => -> { %w[power energy temperature humidity battery] } }.freeze
    FORM_FREE = %w[area tag unchanged_min exclude].freeze

    # As regras de hoje do cartão de área, escritas como dado (o padrão do local).
    AREA_DEFAULTS = [
      { "id" => "on", "label_key" => "on", "icon" => "light-bulb", "query" => { "capability" => "onoff", "state" => "on" }, "aggregate" => "count" },
      { "id" => "open", "label_key" => "open", "icon" => "view-boards", "query" => { "capability" => "contact,gate", "state" => "on" }, "aggregate" => "count" },
      { "id" => "motion", "label_key" => "motion", "icon" => "eye", "query" => { "capability" => "motion", "state" => "on" }, "aggregate" => "any" },
      { "id" => "power", "icon" => "lightning-bolt", "query" => { "device_class" => "power" }, "aggregate" => "sum", "format" => "W" },
      { "id" => "offline", "label_key" => "offline", "icon" => "status-offline", "query" => { "quality" => "stale,unavailable,error" }, "aggregate" => "count", "tone" => "warn" }
    ].freeze

    module_function

    def msg(key, **vars) = I18n.t("dashboards.facts.errors.#{key}", **vars)

    # Os itens do cartão de área do local (o que está em Configurações, ou o padrão).
    def area_defaults(site) = Array(site.settings.to_h.dig("dashboard_defaults", "area_facts")).presence || AREA_DEFAULTS

    # [fatos prontos, pontos de que dependem]. `scope`: filtros juntados a toda consulta (ex.: a área).
    # `url`: lambda(id do fato) → caminho da lista dos pontos (ideia 14), ou nil.
    def resolve(r, facts, scope: {}, url: nil)
      deps = []
      list = Array(facts).first(MAX).filter_map do |f|
        q = f["query"].to_h.merge(scope)
        deps.concat(r.query(q, with_state: false))
        points = r.query(q)
        one(f, points, url)
      end
      [ list, deps.uniq ]
    end

    # Os pontos que entram num fato (a lista do toque, ideia 14).
    def points(r, fact, scope: {}) = r.query(fact["query"].to_h.merge(scope))

    def one(f, points, url)
      agg = f["aggregate"].presence_in(AGGREGATES) || "count"
      value = value(agg, points)
      count = agg.in?(%w[count any]) ? points.size : value
      return nil unless f["show"] == "always" || present?(value)

      { "id" => f["id"], "text" => text(f, agg, value, points), "icon" => f["icon"].presence, "tone" => f["tone"].presence_in(TONES),
        "value" => value, "count" => count, "num" => !agg.in?(%w[count any]) || nil, "url" => url&.call(f["id"]) }.compact
    end

    def value(agg, points)
      return points.size if agg == "count"
      return points.any? if agg == "any"

      nums = points.select { |p| p.quality == "good" }.map(&:value).grep(Numeric)
      return nil if nums.empty?

      v = { "sum" => nums.sum, "avg" => nums.sum.to_f / nums.size, "min" => nums.min, "max" => nums.max }[agg]
      v.round(1)
    end

    def present?(value) = value.is_a?(Numeric) ? !value.zero? : value.present?

    # Texto pelo I18n: {zero, one, other} (ou a chave da casa) escolhido pela contagem; `%{count}` = o número formatado.
    def text(f, agg, value, points)
      number = agg == "any" ? nil : format(value, f["format"].presence || (points.filter_map(&:unit).first unless agg == "count"))
      forms = label_forms(f)
      return number.to_s if forms.blank?

      n = agg == "any" ? (value ? 1 : 0) : value.to_f
      pick = n.zero? ? forms["zero"].presence || forms["other"] : (n == 1 ? forms["one"].presence || forms["other"] : forms["other"])
      pick.to_s.gsub("%{count}", number.to_s).squish
    end

    def label_forms(f)
      label = f["label"]
      return LABEL_FORMS.index_with { |k| label.to_s } if label.is_a?(String) && label.present?
      return label.slice(*LABEL_FORMS).compact_blank if label.is_a?(Hash) && label.slice(*LABEL_FORMS).compact_blank.any?
      return nil if f["label_key"].blank?

      forms = I18n.t("dashboards.facts.labels.#{f['label_key']}", default: nil)
      forms.is_a?(Hash) ? forms.transform_keys(&:to_s).slice(*LABEL_FORMS) : nil
    end

    def format(value, unit)
      return nil if value.nil?

      n = ApplicationController.helpers.number_with_precision(value, precision: value.is_a?(Integer) || value.to_f.abs >= 100 ? 0 : 1,
                                                                     strip_insignificant_zeros: true, delimiter: I18n.t("number.format.delimiter"))
      [ n, unit.presence ].compact.join(" ")
    end

    # Validação (Schema e o formulário de padrões): mensagens sem o "onde".
    def errors(facts)
      return [ msg(:list, max: MAX) ] unless facts.is_a?(Array) && facts.size <= MAX

      ids = []
      facts.flat_map.with_index(1) do |f, n|
        next [ msg(:object, n: n) ] unless f.is_a?(Hash)

        e = []
        e << msg(:id, n: n) unless f["id"].to_s.match?(ID) && !ids.include?(f["id"])
        ids << f["id"]
        e << msg(:query, n: n) unless f["query"].is_a?(Hash) && (f["query"].keys - Points::Query::KEYS).empty?
        e << msg(:aggregate, n: n) if f.key?("aggregate") && !AGGREGATES.include?(f["aggregate"])
        e << msg(:show, n: n) if f.key?("show") && !SHOWS.include?(f["show"])
        e << msg(:tone, n: n) if f.key?("tone") && !TONES.include?(f["tone"])
        e << msg(:label, n: n) if f.key?("label") && !(f["label"].is_a?(String) || (f["label"].is_a?(Hash) && (f["label"].keys - LABEL_FORMS).empty?))
        e
      end
    end

    # Texto `chave=valor` do formulário; inválido volta como `{"text" => ...}` para o Schema acusar a consulta.
    def text_query(text)
      Points::Query.parse(text.to_s)
    rescue ArgumentError
      { "text" => text.to_s }
    end

    # Divide a consulta em [o que os campos mostram, o resto em texto `chave=valor`].
    def split_query(query)
      query = query.to_h.stringify_keys
      shown = query.select { |k, v| FORM_FREE.include?(k) || FORM_SINGLE[k]&.call&.include?(v.to_s) }
      rest = query.except(*shown.keys).map { |k, v| v.to_s.include?(" ") ? "#{k}=\"#{v}\"" : "#{k}=#{v}" }.join(" ")
      [ shown, rest ]
    end

    # Linhas do formulário (Configurações → Padrões e o editor do cartão) → lista de fatos. Linha sem consulta some.
    def from_form(rows)
      rows = rows.respond_to?(:values) ? rows.values : Array(rows)
      rows.filter_map do |row|
        row = row.to_h.stringify_keys
        query = row["query"].to_h.stringify_keys.compact_blank.merge(text_query(row["query_text"]))
        next if query.empty? || row["remove"] == "1"

        label = LABEL_FORMS.index_with { |k| row.dig("label", k).to_s.strip }.compact_blank
        { "id" => row["id"].to_s.parameterize(separator: "_").presence || "f#{SecureRandom.hex(3)}",
          "label" => label.presence, "label_key" => (row["label_key"].presence if label.empty?), "icon" => row["icon"].presence,
          "query" => query, "aggregate" => row["aggregate"].presence_in(AGGREGATES), "show" => (row["show"] if row["show"] == "always"),
          "tone" => row["tone"].presence_in(TONES), "format" => row["format"].to_s.strip.presence }.compact
      end
    end
  end
end
