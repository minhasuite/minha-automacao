module Dashboards
  # Estilo condicional genérico (`style_if`, P1.2 da proposta de
  # personalização): lista de regras em qualquer widget; a primeira cujo `when`
  # bate (a mesma condição do `visible_if`, sem papel nem tela; sem `when` =
  # sempre) decide `color`, `icon`, `label`, `tone` e `badge`. O Resolver
  # avalia (`Resolver#decorate`); web e app só aplicam.
  #
  #   "style_if": [ { "when": { "state": { "point": "sala.porta", "is": "open" }, "time": { "after": "22:00", "before": "06:00" } },
  #                   "tone": "danger", "badge": "Aberta à noite", "icon": "lock-open" } ]
  module Style
    PROPS = %w[color icon label].freeze
    FLAGS = %w[tone badge].freeze
    KEYS = (%w[when] + PROPS + FLAGS).freeze
    TONES = Facts::TONES
    MAX = 10
    # Campos de cada linha do formulário (strong params).
    FORM_FIELDS = %i[point is negate above below after before when_json color icon label tone badge remove].freeze

    module_function

    def msg(key, **vars) = I18n.t("dashboards.style.errors.#{key}", **vars)

    # Mensagens sem o "onde"; a condição é validada pelo `Schema.visible_if` (quem chama passa).
    def errors(rules, &check_when)
      return [ msg(:list, max: MAX) ] unless rules.is_a?(Array) && rules.size.between?(1, MAX)

      rules.flat_map.with_index(1) do |r, n|
        next [ msg(:object, n: n) ] unless r.is_a?(Hash)

        e = []
        e << msg(:unknown, n: n, keys: KEYS.join(", ")) unless (r.keys - KEYS).empty?
        e << msg(:empty, n: n) if r.slice(*PROPS, *FLAGS).compact_blank.empty?
        e << msg(:tone, n: n, tones: TONES.join(", ")) if r.key?("tone") && !TONES.include?(r["tone"])
        e << msg(:color, n: n, colors: Schema::COLORS.join(", ")) if r.key?("color") && !Schema::COLORS.include?(r["color"])
        e << msg(:text, n: n) if r.slice("label", "badge", "icon").values.any? { |v| !v.is_a?(String) || v.size > 80 }
        e.concat(Array(check_when&.call(r["when"], n))) if r.key?("when")
        e
      end
    end

    # Formulário do editor → regras. Cada linha: um ponto + estado/faixa (+ janela de horário); a condição
    # que o formulário não sabe mostrar (OU, qualidade...) vem em `when_json` e volta igual.
    def from_form(rows)
      rows = rows.respond_to?(:values) ? rows.values : Array(rows)
      rows.filter_map do |row|
        row = row.to_h.stringify_keys
        next if row["remove"] == "1"

        rule = { "when" => condition(row), "color" => row["color"].presence_in(Schema::COLORS), "icon" => row["icon"].to_s.strip.presence,
                 "label" => row["label"].to_s.strip.presence, "tone" => row["tone"].presence_in(TONES), "badge" => row["badge"].to_s.strip.presence }.compact
        rule if rule.except("when").any?
      end.presence
    end

    def condition(row)
      kept = parse(row["when_json"])
      return kept if kept.is_a?(Hash)

      cond = {}
      if row["point"].present?
        if row["above"].present? || row["below"].present?
          cond["numeric"] = { "point" => row["point"], "above" => Widgets::Base.number(row["above"]), "below" => Widgets::Base.number(row["below"]) }.compact
        elsif row["is"].present?
          cond["state"] = { "point" => row["point"], (row["negate"] == "1" ? "not" : "is") => cast(row["is"]) }
        end
      end
      time = { "after" => row["after"].presence, "before" => row["before"].presence }.compact
      cond["time"] = time if time.any?
      cond.presence
    end

    def parse(json)
      JSON.parse(json) if json.present?
    rescue JSON::ParserError
      nil
    end

    # "true"/"false"/número do formulário viram o valor do ponto.
    def cast(v) = { "true" => true, "false" => false }.fetch(v.to_s.strip) { Widgets::Base.number(v) || v.to_s.strip }

    # A regra cabe no formulário simples (um ponto com estado ou faixa, e/ou horário)?
    def simple?(cond)
      return true if cond.blank?
      return false unless cond.is_a?(Hash) && (cond.keys - %w[state numeric time]).empty? && !(cond.key?("state") && cond.key?("numeric"))
      return false if cond.key?("state") && (Array(cond.dig("state", "is") || cond.dig("state", "not")).size > 1 || (cond["state"].key?("is") && cond["state"].key?("not")))

      true
    end
  end
end
