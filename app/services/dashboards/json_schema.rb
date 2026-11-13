module Dashboards
  # JSON Schema (2020-12) do painel, gerado do registro (P1.5): os tipos de
  # widget saem de `Dashboards::Widgets` (`describe type:, label:, required:,
  # params:, bind:, binds:`) e o que cada plugin acrescentar em `schema_props`;
  # as listas fechadas (cores, agregações, telas, papéis, chaves de consulta,
  # tipos de visão...) saem das constantes de quem valida. Serve para
  # autocompletar no editor de JSON e para documentar (`/paineis/schema.json`).
  # Quem manda continua sendo o `Dashboards::Schema` (a validação de verdade);
  # isto é a descrição para pessoas e ferramentas.
  module JsonSchema
    ID = "/paineis/schema.json".freeze
    # Prop → esquema, pelo nome (vale para qualquer tipo que a use). Plugin pode trocar/estender em `schema_props`.
    STRING = { "type" => "string" }.freeze

    module_function

    def call
      { "$schema" => "https://json-schema.org/draft/2020-12/schema", "$id" => ID, "title" => t(:title), "description" => t(:description),
        "type" => "object", "required" => %w[schema_version views],
        "properties" => { "schema_version" => { "const" => Schema::VERSION }, "theme" => { "$ref" => "#/$defs/theme" },
                          "views" => { "type" => "array", "minItems" => 1, "items" => { "$ref" => "#/$defs/view" } } },
        "$defs" => defs }
    end

    # Só um tipo (o painel lateral do editor de JSON do widget): {type, label, required, props}.
    def for_type(type)
      plugin = Widgets[type] or return nil
      { "type" => plugin.type, "label" => plugin.label, "required" => plugin.required, "props" => widget_props(plugin).keys.sort }
    end

    def defs
      {
        "span" => { "type" => "object", "description" => t(:span), "additionalProperties" => false,
                    "properties" => Schema::SCREENS.index_with { { "type" => "integer", "minimum" => 1, "maximum" => 12 } } },
        "theme" => { "type" => "object", "additionalProperties" => false, "properties" => Themes::KEYS.index_with { {} } },
        "query" => { "type" => "object", "description" => t(:query), "additionalProperties" => false,
                     "properties" => Points::Query::KEYS.index_with { { "type" => %w[string number boolean] } }
                       .merge("capability" => { "anyOf" => [ { "enum" => Point::CAPABILITIES.keys }, { "type" => "array", "items" => { "enum" => Point::CAPABILITIES.keys } }, STRING ] },
                              "state" => { "enum" => Schema::STATES }) },
        "condition" => { "type" => "object", "description" => t(:visible_if), "additionalProperties" => false,
                         "properties" => Schema::VISIBILITY.index_with { {} }.merge(
                           "role" => { "type" => "array", "items" => { "enum" => SiteMembership::ROLES } },
                           "screen" => { "type" => "array", "items" => { "enum" => Schema::SCREENS } },
                           "quality" => { "type" => "array", "items" => { "enum" => Point::QUALITIES } },
                           "time" => { "type" => "object", "properties" => { "after" => { "type" => "string", "pattern" => Schema::TIME.source.delete_prefix("\\A").delete_suffix("\\z") },
                                                                             "before" => { "type" => "string" } } },
                           "any" => { "type" => "array", "maxItems" => Schema::MAX_ANY, "items" => { "$ref" => "#/$defs/condition" } },
                           "all" => { "type" => "array", "maxItems" => Schema::MAX_ANY, "items" => { "$ref" => "#/$defs/condition" } }) },
        "style_rule" => { "type" => "object", "description" => t(:style_if), "additionalProperties" => false,
                          "properties" => Style::KEYS.index_with { STRING }.merge("when" => { "$ref" => "#/$defs/condition" }, "tone" => { "enum" => Style::TONES },
                                                                                  "color" => { "enum" => Schema::COLORS }) },
        "view" => view,
        "section" => { "type" => "object", "required" => %w[id widgets], "properties" => {
          "id" => id, "title" => STRING, "span" => { "$ref" => "#/$defs/span" }, "position" => { "enum" => ViewTypes::POSITIONS },
          "widgets" => { "type" => "array", "items" => { "$ref" => "#/$defs/widget" } }
        } },
        "widget" => widget,
        **Widgets.plugins.to_h { |p| [ "widget_#{p.type}", widget_type(p) ] }
      }
    end

    def view
      { "type" => "object", "required" => %w[id title sections], "properties" => {
        "id" => id, "title" => STRING, "icon" => STRING, "path" => { "type" => "string", "pattern" => "^[a-z0-9][a-z0-9-]{0,39}$" },
        "type" => { "enum" => ViewTypes.plugins.map(&:key) }, "subview" => { "type" => "boolean" }, "back_path" => STRING,
        "area" => STRING, "theme" => { "$ref" => "#/$defs/theme" },
        # visao-entrega: a visão só para algumas telas, papéis ou aparelhos.
        "visible_if" => { "type" => "object", "description" => t(:view_visible_if), "additionalProperties" => false, "minProperties" => 1,
                          "properties" => { "role" => { "type" => "array", "items" => { "enum" => SiteMembership::ROLES } },
                                            "screen" => { "type" => "array", "minItems" => 1, "items" => { "enum" => Schema::SCREENS } },
                                            "device" => { "type" => "array" } } },
        "hero" => { "type" => "object", "description" => t(:hero), "additionalProperties" => false,
                    "properties" => { "title" => STRING, "kicker" => STRING, "greeting" => { "type" => "boolean" }, "hide" => { "type" => "boolean" } } },
        "badges" => { "type" => "array", "items" => { "$ref" => "#/$defs/widget" } },
        "sections" => { "type" => "array", "items" => { "$ref" => "#/$defs/section" } }
      } }
    end

    # Comum a todo widget + o `if type = X then widget_X`.
    def widget
      { "type" => "object", "required" => %w[id type], "properties" => common,
        "allOf" => Widgets.plugins.map { |p| { "if" => { "properties" => { "type" => { "const" => p.type } } }, "then" => { "$ref" => "#/$defs/widget_#{p.type}" } } } }
    end

    def common
      {
        "id" => id, "type" => { "enum" => Widgets.plugins.map(&:type), "description" => t(:type) },
        "label" => { "type" => "string", "description" => t(:label) }, "span" => { "$ref" => "#/$defs/span" },
        "visible_if" => { "$ref" => "#/$defs/condition" }, "style_if" => { "type" => "array", "maxItems" => Style::MAX, "items" => { "$ref" => "#/$defs/style_rule" } },
        "stale_after_min" => { "type" => "integer", "minimum" => 0, "maximum" => Staleness::MAX_MIN, "description" => t(:stale_after_min) },
        "color" => { "enum" => Schema::COLORS }, "icon" => STRING
      }.merge(Actions::GESTURES.values.index_with { { "type" => "object" } })
    end

    def widget_type(plugin)
      { "description" => plugin.label, "required" => plugin.required, "properties" => widget_props(plugin) }
    end

    # Props do tipo: bind/binds, os params do editor (pelo nome), os filhos da pilha e o que o plugin acrescentar.
    def widget_props(plugin)
      props = {}
      props["bind"] = { "type" => "string", "description" => t(:bind) } if plugin.bind? || plugin.required.include?("bind")
      props["binds"] = { "type" => "array", "maxItems" => 8, "items" => STRING, "description" => t(:binds) } if plugin.binds? || plugin.required.include?("binds")
      Array(plugin.params).each { |k| props[k.to_s] ||= by_name(k.to_s) }
      plugin.required.each { |k| props[k] ||= by_name(k) }
      props["widgets"] = { "type" => "array", "maxItems" => Schema::MAX_CHILDREN, "items" => { "$ref" => "#/$defs/widget" } } if plugin.container?
      props.merge(plugin.schema_props)
    end

    # Esquema de uma prop pelo nome (as listas fechadas que o Schema valida).
    def by_name(key)
      {
        "aggregate" => { "enum" => Schema::AGGREGATES }, "period" => { "enum" => Schema::PERIODS }, "range" => { "enum" => Schema::RANGES },
        "tap" => { "enum" => Schema::TAPS }, "query" => { "$ref" => "#/$defs/query" }, "live" => { "type" => "boolean" },
        "snapshot_interval" => { "type" => "integer", "minimum" => 2, "maximum" => 300 }, "min" => { "type" => "number" }, "max" => { "type" => "number" },
        "features" => { "type" => "array" }, "facts" => { "type" => "array", "maxItems" => Facts::MAX, "description" => t(:facts) },
        "scenes" => { "type" => "array", "items" => STRING }
      }.fetch(key) { STRING }
    end

    def id = { "type" => "string", "pattern" => "^[\\w-]{1,100}$" }
    def t(key) = I18n.t("dashboards.json_schema.#{key}")
  end
end
