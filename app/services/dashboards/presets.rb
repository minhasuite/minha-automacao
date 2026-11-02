module Dashboards
  # Predefinições de painel (o painel de Energia do HA, sem módulo especial):
  # um gerador monta a definição com widgets comuns a partir dos pontos que a
  # pessoa escolhe; o resultado é um painel como qualquer outro (editor,
  # versões, API, app). Predefinição nova = classe em `Presets` (herda de
  # `Base`: `describe`, `fields` e `build(site, form)` → definição) + nome em
  # `PLUGINS`; a tela de escolha e a criação não mudam.
  module Presets
    PLUGINS = %w[EnergyPreset].freeze

    module_function

    def plugins = PLUGINS.map { |n| const_get(n) }
    def [](key) = plugins.find { |p| p.key == key.to_s }

    # Monta, valida pelo Schema e publica. → [painel, erros].
    def create!(site, preset, form, author: Current.user)
      form = form.to_h.with_indifferent_access
      errors = preset.errors(site, form)
      return [ nil, errors ] if errors.any?

      definition = preset.build(site, form)
      errors = Schema.errors(definition)
      return [ nil, errors ] if errors.any?

      dashboard = site.dashboards.create!(name: form[:name].presence&.first(80) || preset.title, kind: "custom", icon: preset.icon.presence_in(Dashboard::ICONS), definition: definition)
      dashboard.publish!(definition, author: author)
      [ dashboard, [] ]
    end

    class Base
      extend PluginTexts
      translates :title, :description

      # Campo do formulário: `kind` :point (um), :points (vários, até 8),
      # :number ou :text; `filter` escolhe os pontos que aparecem.
      Field = Struct.new(:key, :label, :kind, :hint, :filter, keyword_init: true)

      class << self
        attr_reader :key, :icon

        def describe(key:, title:, icon:, description:)
          @key = key
          @title = title
          @icon = icon
          @description = description
        end

        # Rótulo e dica no idioma da tela (`texts` com "fields.<campo>" e "hints.<campo>").
        def fields(list = nil)
          @fields = list.map { |f| Field.new(**f) } if list
          (@fields || []).map do |f|
            Field.new(**f.to_h.merge(label: text("fields.#{f.key}", default: f.label), hint: f.hint && text("hints.#{f.key}", default: f.hint)))
          end
        end

        # Os campos também pedem en/es (spec/i18n_coverage_spec.rb).
        def source_texts
          (@fields || []).each_with_object(super) do |f, h|
            h["fields.#{f.key}"] = f.label
            h["hints.#{f.key}"] = f.hint if f.hint
          end
        end

        def build(_site, _form) = raise(NotImplementedError)
        # Erros do formulário antes de montar (vazio = pode montar).
        def errors(_site, _form) = []

        # Pontos do formulário que são mesmo do local (ids na ordem dada).
        def pick(site, ids)
          ids = Array(ids).compact_blank.uniq
          found = site.points.where(id: ids).index_by(&:id)
          ids.filter_map { |id| found[id] }
        end

        def widget(id, type, desktop: 6, **props) = { "id" => id, "type" => type, "span" => { "mobile" => 12, "tablet" => 12, "desktop" => desktop } }.merge(props.stringify_keys).compact
        def section(id, title, icon, widgets) = { "id" => id, "title" => title, "icon" => icon, "widgets" => widgets }
      end
    end

    # Energia: fluxo agora, consumo e custo do mês com meta e projeção,
    # comparação dia/semana/mês, ranking por aparelho e potência em 24 h.
    class EnergyPreset < Base
      POWER = ->(p) { Energy.power?(p) && p.numeric? }
      ENERGY = ->(p) { Energy.supported?(p) }
      PERCENT = ->(p) { p.numeric? && p.unit.to_s == "%" }
      TARIFF = ->(p) { p.numeric? && (p.helper.in?(%w[tariff number]) || p.unit.to_s.include?("R$")) }

      describe key: "energy", title: "Energia", icon: "lightning-bolt",
               description: "Fluxo rede, solar e bateria, consumo e custo com meta e projeção, comparação dia/semana/mês e ranking por aparelho."
      texts en: { title: "Energy", description: "Grid, solar and battery flow, usage and cost with goal and projection, day/week/month comparison and ranking by device.",
                  fields: { grid: "Grid power", solar: "Solar generation", battery: "Battery power", battery_soc: "Battery charge", consumption: "Usage meters",
                            tariff_point: "Rate", tariff: "Or fixed rate (per kWh)", goal: "Monthly goal (kWh)" },
                  hints: { grid: "W or kW; positive = buying from the utility", solar: "optional", battery: "optional; positive = discharging", battery_soc: "optional, in %",
                           consumption: "kWh or W; empty = the grid", tariff_point: "Rate helper (time-of-use) or Number", tariff: "0.95", goal: "optional" },
                  need_one: "pick at least the grid power, the solar or a usage meter",
                  gen: { flow: "Energy now", month: "This month", now: "Now", compare: "Comparison", today: "Today", rank: "By device", power: "Power", last_24h: "Last 24 h" } },
            es: { title: "Energía", description: "Flujo de red, solar y batería, consumo y costo con meta y proyección, comparación día/semana/mes y ranking por aparato.",
                  fields: { grid: "Potencia de la red", solar: "Generación solar", battery: "Potencia de la batería", battery_soc: "Carga de la batería", consumption: "Medidores de consumo",
                            tariff_point: "Tarifa", tariff: "O tarifa fija (por kWh)", goal: "Meta del mes (kWh)" },
                  hints: { grid: "W o kW; positivo = comprando a la distribuidora", solar: "opcional", battery: "opcional; positivo = descargando", battery_soc: "opcional, en %",
                           consumption: "kWh o W; vacío = la red", tariff_point: "helper Tarifa (horaria) o Número", tariff: "0.95", goal: "opcional" },
                  need_one: "elige al menos la potencia de la red, la solar o un medidor de consumo",
                  gen: { flow: "Energía ahora", month: "Este mes", now: "Ahora", compare: "Comparación", today: "Hoy", rank: "Por aparato", power: "Potencia", last_24h: "Últimas 24 h" } },
            "pt-BR" => { need_one: "escolha ao menos a potência da rede, o solar ou um medidor de consumo",
                         gen: { flow: "Energia agora", month: "Este mês", now: "Agora", compare: "Comparação", today: "Hoje", rank: "Por aparelho", power: "Potência", last_24h: "Últimas 24 h" } }
      fields [
        { key: "grid", label: "Potência da rede", kind: :point, hint: "W ou kW; positivo = comprando da distribuidora", filter: POWER },
        { key: "solar", label: "Geração solar", kind: :point, hint: "opcional", filter: POWER },
        { key: "battery", label: "Potência da bateria", kind: :point, hint: "opcional; positivo = descarregando", filter: POWER },
        { key: "battery_soc", label: "Carga da bateria", kind: :point, hint: "opcional, em %", filter: PERCENT },
        { key: "consumption", label: "Medidores de consumo", kind: :points, hint: "kWh ou W; vazio = a rede", filter: ENERGY },
        { key: "tariff_point", label: "Tarifa", kind: :point, hint: "helper Tarifa (tarifa branca) ou Número", filter: TARIFF },
        { key: "tariff", label: "Ou tarifa fixa (R$/kWh)", kind: :number, hint: "0,95" },
        { key: "goal", label: "Meta do mês (kWh)", kind: :number, hint: "opcional" }
      ]

      def self.errors(site, form)
        any = %w[grid solar].any? { |k| pick(site, [ form[k] ]).any? } || pick(site, form[:consumption]).any?(&ENERGY)
        any ? [] : [ text(:need_one) ]
      end

      def self.build(site, form)
        one = ->(k) { pick(site, [ form[k] ]).first }
        grid, solar, battery, soc, tariff_point = %w[grid solar battery battery_soc tariff_point].map { |k| one.(k) }
        chosen = pick(site, form[:consumption]).select(&ENERGY).first(8)
        meters = chosen.presence || [ grid ].compact
        tariff = Widgets::Base.number(form[:tariff]) unless tariff_point
        goal = Widgets::Base.number(form[:goal])
        price = { "tariff_point" => tariff_point&.id, "tariff" => tariff }
        binds = meters.map(&:id)
        now = []
        if grid || solar
          now << widget("en-flow", "energy_flow", label: text("gen.flow"), grid: grid&.id, solar: solar&.id, battery: battery&.id, battery_soc: soc&.id)
        end
        now << widget("en-month", "energy", label: text("gen.month"), binds: binds, period: "month", goal: (goal if goal&.positive?), compare: true, **price) if binds.any?
        sections = [ section("en-now", text("gen.now"), "lightning-bolt", now) ]
        if binds.any?
          sections << section("en-cmp", text("gen.compare"), "trending-up", [
                                widget("en-today", "energy", label: text("gen.today"), binds: binds, period: "today", compare: true, **price),
                                widget("en-compare", "energy_compare", binds: binds, **price)
                              ])
        end
        sections << section("en-rank", text("gen.rank"), "chart-bar", [ widget("en-breakdown", "energy_breakdown", period: "month", binds: chosen.map(&:id).presence, **price) ])
        power = [ grid, solar, battery ].compact.map(&:id)
        sections << section("en-power", text("gen.power"), "chart-bar", [ widget("en-chart", "chart", desktop: 12, label: text("gen.last_24h"), binds: power, range: "24h") ]) if power.any?
        { "schema_version" => 1,
          "views" => [ { "id" => "energia", "title" => title, "icon" => "lightning-bolt", "sections" => sections.reject { |s| s["widgets"].empty? } } ] }
      end
    end
  end
end
