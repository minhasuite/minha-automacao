module Dashboards
  # Regras de arrumação como dado (P2.1 da proposta de personalização).
  #
  # Duas listas de regras por local, em `sites.settings["dashboard_defaults"]`
  # (Configurações → Painéis → Arrumação), cada uma com o padrão escrito aqui
  # como dado (as tabelas e regex que viviam no código):
  #
  # - `arrange` (visões de cômodo, `Dashboards::RoomLayout`): o painel pode ter
  #   a sua no próprio JSON (`definition["arrange"]`), que vale no lugar da do local.
  #
  #     { "badges"  => { "widgets" => ["tile", "stat"], "match" => [{ "query" => {...} }], "icons" => { classe => ícone } },
  #       "columns" => [{ "id" => "actions", "title" => "...", "full" => ["scene_bar"],
  #                       "match" => [{ "type" => ["light", ...] }, { "query" => {...} }] }],
  #       "fallback" => "media" }
  #
  #   Cada widget vai para o primeiro lugar que vale, nesta ordem: coluna cujo
  #   `type` tem o tipo do widget; pilha/grade = a coluna do primeiro de dentro;
  #   widget sem ponto = `fallback`; selo (tipo em `badges.widgets` e ponto em
  #   alguma consulta de `badges.match`); coluna (na ordem da lista) com
  #   alguma consulta (`Points::Query`) que o ponto do `bind` satisfaz; senão
  #   `fallback`. `full`: tipos que ocupam a coluna inteira fora do celular.
  #
  # - `auto_rules` (painel automático, `Dashboards::Generator`): consultas de
  #   luz (a etiqueta `iluminacao` primeiro; o nome como reserva se
  #   `light_names`), técnico (fica fora das visões), segurança, potência e
  #   quantos medidores entram no gráfico (`power_limit`).
  #
  # Nada aqui comanda nada nem roda código do usuário: consultas só pelo `Points::Query`.
  module Arrange
    MAX_COLUMNS = 4
    MAX_MATCH = 20
    MAX_ICONS = 60
    ID = /\A[a-z0-9_-]{1,30}\z/
    NOT_PLAIN = "script,speaker,media,stream".freeze

    # As tabelas de antes (`TYPE_COLUMN`, `MEDIA_CAPABILITIES`, `BADGE_*`) escritas como dado.
    DEFAULT = {
      "badges" => {
        "widgets" => %w[tile stat],
        "match" => [
          { "query" => { "capability" => "contact,motion,tamper,problem", "commandable" => "false", "automation" => "false" } },
          { "query" => { "device_class" => "door,window,opening,garage_door,gate,motion,occupancy,presence,moisture,leak,smoke,gas," \
                                           "battery,battery_low,problem,tamper,vibration,safety,lock",
                         "commandable" => "false", "automation" => "false", "not_capability" => NOT_PLAIN } }
        ],
        "icons" => {
          "door" => "mdi:door", "window" => "mdi:window-closed-variant", "opening" => "mdi:door", "garage_door" => "mdi:garage",
          "gate" => "mdi:gate", "motion" => "mdi:motion-sensor", "occupancy" => "mdi:account", "presence" => "mdi:account",
          "moisture" => "mdi:water-alert", "leak" => "mdi:water-alert", "smoke" => "mdi:smoke-detector", "gas" => "mdi:gas-cylinder",
          "battery" => "mdi:battery-alert", "battery_low" => "mdi:battery-alert", "problem" => "mdi:alert-circle-outline",
          "tamper" => "mdi:shield-alert-outline", "vibration" => "mdi:vibrate", "contact" => "mdi:door"
        }
      },
      "columns" => [
        { "id" => "actions", "match" => [
          { "type" => %w[thermostat light humidifier vacuum remote alarm button] },
          { "query" => { "commandable" => "true", "automation" => "false", "not_capability" => NOT_PLAIN } }
        ] },
        { "id" => "scenes", "full" => %w[scene_bar], "match" => [
          { "type" => %w[scene_bar] }, { "query" => { "automation" => "true" } }, { "query" => { "capability" => "script" } }
        ] },
        { "id" => "media", "match" => [
          { "type" => %w[camera media chart gauge weather energy energy_flow energy_breakdown energy_compare logbook map image iframe plant] },
          { "query" => { "capability" => "speaker,media,stream" } }
        ] }
      ],
      "fallback" => "media"
    }.freeze

    # As regras de antes do painel automático (regex LIGHT fica de reserva no Generator).
    AUTO_DEFAULT = {
      "light" => [ { "capability" => "onoff,dimmer", "tag" => "iluminacao" } ],
      "light_names" => true,
      "technical" => [ { "capability" => "measure", "device_class" => "voltage,current" }, { "capability" => "measure", "unit" => "V,A,mA" } ],
      "security" => [ { "risk" => "sensitive,critical" }, { "capability" => "gate,contact,motion" } ],
      "power" => [ { "capability" => "measure", "device_class" => "power" } ],
      "power_limit" => 8
    }.freeze
    AUTO_LISTS = %w[light technical security power].freeze

    module_function

    def msg(key, **vars) = I18n.t("arrange.errors.#{key}", **vars)

    def defaults(site) = site.settings.to_h.fetch("dashboard_defaults", nil).to_h

    # As regras de arrumação: as do painel, senão as do local, senão o padrão.
    def rules(site, definition = nil)
      own = definition.to_h["arrange"] if definition.is_a?(Hash)
      own.presence || defaults(site)["arrange"].presence || DEFAULT
    end

    def auto_rules(site) = AUTO_DEFAULT.merge(defaults(site)["auto_rules"].to_h)

    # Validação das regras de arrumação (Schema do painel e a tela de regras).
    def errors(rules)
      return [ msg(:object) ] unless rules.is_a?(Hash)

      e = []
      badges = rules["badges"] || {}
      return [ msg(:badges) ] unless badges.is_a?(Hash)

      e << msg(:types, where: msg(:badges_where)) unless types?(badges["widgets"] || [])
      e.concat(match_errors(badges["match"] || [], msg(:badges_where), types: false))
      icons = badges["icons"] || {}
      e << msg(:icons) unless icons.is_a?(Hash) && icons.size <= MAX_ICONS && icons.all? { |k, v| k.is_a?(String) && v.is_a?(String) && v.size <= 80 }
      cols = rules["columns"]
      return e << msg(:columns, max: MAX_COLUMNS) unless cols.is_a?(Array) && cols.size.between?(1, MAX_COLUMNS)

      ids = []
      cols.each_with_index do |c, i|
        next e << msg(:column, n: i + 1) unless c.is_a?(Hash)

        where = msg(:column_where, id: c["id"] || i + 1)
        e << msg(:id, where: where) unless c["id"].is_a?(String) && c["id"].match?(ID) && !ids.include?(c["id"])
        ids << c["id"]
        e << msg(:title, where: where) if c.key?("title") && !(c["title"].is_a?(String) && c["title"].size <= 60)
        e << msg(:types, where: where) if c.key?("full") && !types?(c["full"])
        e.concat(match_errors(c["match"] || [], where))
      end
      e << msg(:fallback) unless ids.include?(rules["fallback"])
      e
    end

    def match_errors(list, where, types: true)
      return [ msg(:match, where: where, max: MAX_MATCH) ] unless list.is_a?(Array) && list.size <= MAX_MATCH

      list.flat_map do |m|
        next [ msg(:match_item, where: where) ] unless m.is_a?(Hash) && (m.keys - (types ? %w[type query] : %w[query])).empty? && (m["type"] || m["query"])

        out = []
        out << msg(:types, where: where) if m.key?("type") && !types?(m["type"])
        out << msg(:query, where: where, error: query_error(m["query"])) if m.key?("query") && query_error(m["query"])
        out
      end
    end

    def types?(list) = list.is_a?(Array) && list.all? { |t| t.is_a?(String) && Schema.types.key?(t) }

    def query_error(q)
      return msg(:query_object) unless q.is_a?(Hash) && q.any?

      bad = q.keys - Points::Query::KEYS
      bad.any? ? msg(:query_keys, keys: bad.join(", ")) : nil
    end

    # Regras do painel automático: listas de consultas e o limite.
    def auto_errors(rules)
      return [ msg(:object) ] unless rules.is_a?(Hash)

      e = AUTO_LISTS.flat_map do |k|
        list = rules[k]
        next [] if list.nil?
        next [ msg(:auto_list, list: k, max: MAX_MATCH) ] unless list.is_a?(Array) && list.size <= MAX_MATCH

        list.filter_map { |q| (err = query_error(q)) && msg(:query, where: k, error: err) }
      end
      e << msg(:power_limit) if rules.key?("power_limit") && !(rules["power_limit"].is_a?(Integer) && rules["power_limit"].between?(1, 8))
      e
    end

    # --- Formulário (Configurações → Painéis → Arrumação) ---

    # {"capability" => "onoff", "area" => "Sala de estar"} → `capability=onoff area="Sala de estar"`.
    def query_text(q) = q.to_h.map { |k, v| v.to_s.include?(" ") ? "#{k}=\"#{v}\"" : "#{k}=#{v}" }.join(" ")

    # Uma consulta por linha → lista (ArgumentError com a linha ruim).
    def queries_from(text)
      text.to_s.lines.map(&:strip).compact_blank.map { |line| Points::Query.parse(line) }
    end

    def list_from(text) = text.to_s.split(/[\s,]+/).map(&:strip).compact_blank.uniq

    # "classe=ícone" por linha.
    def icons_from(text)
      text.to_s.lines.map(&:strip).compact_blank.to_h { |l| l.split("=", 2).map(&:strip) }.reject { |k, v| k.blank? || v.blank? }
    end

    # Formulário → regras de arrumação (levanta ArgumentError com a mensagem para a tela).
    def from_form(form)
      form = form.to_h.deep_stringify_keys
      badges = form["badges"].to_h
      columns = form["columns"].to_h.sort_by { |k, _| k.to_i }.map(&:last).filter_map do |c|
        next if c["remove"] == "1" || c["id"].blank?

        match = [ ({ "type" => list_from(c["types"]) } if list_from(c["types"]).any?), *queries_from(c["queries"]).map { |q| { "query" => q } } ].compact
        { "id" => c["id"].to_s.strip.parameterize(separator: "_"), "title" => c["title"].to_s.strip.presence,
          "full" => list_from(c["full"]).presence, "match" => match }.compact
      end
      { "badges" => { "widgets" => list_from(badges["widgets"]), "match" => queries_from(badges["queries"]).map { |q| { "query" => q } },
                      "icons" => icons_from(badges["icons"]) },
        "columns" => columns, "fallback" => form["fallback"].to_s.strip }
    end

    def auto_from_form(form)
      form = form.to_h.stringify_keys
      AUTO_LISTS.to_h { |k| [ k, queries_from(form[k]) ] }
                .merge("light_names" => form["light_names"] == "1", "power_limit" => form["power_limit"].to_i.clamp(1, 8))
    end
  end
end
