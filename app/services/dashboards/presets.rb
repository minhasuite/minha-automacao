module Dashboards
  # Predefinições de painel (o painel de Energia do HA, sem módulo especial):
  # um gerador monta a definição com widgets comuns a partir dos pontos que a
  # pessoa escolhe; o resultado é um painel como qualquer outro (editor,
  # versões, API, app). Predefinição nova = classe em `Presets` (herda de
  # `Base`: `describe`, `fields` e `build(site, form)` → definição) + nome em
  # `PLUGINS`; a tela de escolha e a criação não mudam.
  #
  # P2.2: predefinição também é **dado** (`DataPreset`), sem classe: o item
  # `preset` de um pacote (`fields` com os mesmos `kind` + a definição com
  # `{{ fields.<campo> }}`) e a biblioteca embutida de painéis prontos
  # (ideia 20, `config/dashboard_library/*.yml`, cada um um manifesto de
  # pacote). A tela lista os três (`all`): classes, biblioteca e pacotes do local.
  module Presets
    PLUGINS = %w[EnergyPreset HealthPreset].freeze
    LIBRARY = Rails.root.join("config/dashboard_library")

    module_function

    def plugins = PLUGINS.map { |n| const_get(n) }
    def [](key) = plugins.find { |p| p.key == key.to_s }

    # Manifestos da biblioteca embutida (só dados, validados pelo spec como pacote).
    def library_manifests
      @library_manifests ||= Dir[LIBRARY.join("*.yml")].sort.map { |f| YAML.safe_load_file(f, aliases: false).freeze }.freeze
    end

    def library = library_manifests.flat_map { |m| DataPreset.from_manifest(m, source: :library) }

    # As dos pacotes instalados no local (chave "<pacote>--<item>").
    def from_packages(site)
      site.packages.ordered.flat_map { |pk| DataPreset.from_manifest(pk.manifest, source: :package, package: pk) }
    end

    def all(site) = plugins + library + from_packages(site)
    def find(site, key) = all(site).find { |p| p.key == key.to_s }

    # Monta, valida pelo Schema e publica. → [painel, erros].
    def create!(site, preset, form, author: Current.user)
      form = form.to_h.with_indifferent_access
      errors = preset.errors(site, form)
      return [ nil, errors ] if errors.any?

      definition = preset.build(site, form)
      errors = Schema.errors(definition)
      return [ nil, errors ] if errors.any?

      preset.prepare!(site) if preset.respond_to?(:prepare!) # modelos de card que a predefinição usa
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
      VOLUME = ->(p) { Meter.supported?(p) }

      describe key: "energy", title: "Energia", icon: "lightning-bolt",
               description: "Fluxo rede, solar e bateria, consumo e custo com meta e projeção, comparação dia/semana/mês e ranking por aparelho."
      texts en: { title: "Energy", description: "Grid, solar and battery flow, usage and cost with goal and projection, day/week/month comparison and ranking by device.",
                  fields: { grid: "Grid power", solar: "Solar generation", battery: "Battery power", battery_soc: "Battery charge", consumption: "Usage meters",
                            tariff_point: "Rate", tariff: "Or fixed rate (per kWh)", goal: "Monthly goal (kWh)",
                            gas: "Gas meter", gas_tariff: "Gas rate (per m³)", water: "Water meter", water_tariff: "Water rate (per m³)",
                            co2: "Grid fossil share", solar_forecast: "Today's solar forecast" },
                  hints: { grid: "W or kW; positive = buying from the utility", solar: "optional", battery: "optional; positive = discharging", battery_soc: "optional, in %",
                           consumption: "kWh or W; empty = the grid", tariff_point: "Rate helper (time-of-use) or Number", tariff: "0.95", goal: "optional",
                           gas: "optional; cumulative m³ or L", gas_tariff: "optional", water: "optional; cumulative m³ or L", water_tariff: "optional",
                           co2: "optional, in % (e.g. Electricity Maps)", solar_forecast: "optional, in kWh (e.g. Forecast.Solar)" },
                  need_one: "pick at least the grid power, the solar or a usage meter",
                  gen: { flow: "Energy now", month: "This month", now: "Now", compare: "Comparison", today: "Today", rank: "By device", power: "Power", last_24h: "Last 24 h", utility: "Gas and water" } },
            es: { title: "Energía", description: "Flujo de red, solar y batería, consumo y costo con meta y proyección, comparación día/semana/mes y ranking por aparato.",
                  fields: { grid: "Potencia de la red", solar: "Generación solar", battery: "Potencia de la batería", battery_soc: "Carga de la batería", consumption: "Medidores de consumo",
                            tariff_point: "Tarifa", tariff: "O tarifa fija (por kWh)", goal: "Meta del mes (kWh)",
                            gas: "Medidor de gas", gas_tariff: "Tarifa del gas (por m³)", water: "Medidor de agua", water_tariff: "Tarifa del agua (por m³)",
                            co2: "Parte fósil de la red", solar_forecast: "Previsión solar de hoy" },
                  hints: { grid: "W o kW; positivo = comprando a la distribuidora", solar: "opcional", battery: "opcional; positivo = descargando", battery_soc: "opcional, en %",
                           consumption: "kWh o W; vacío = la red", tariff_point: "helper Tarifa (horaria) o Número", tariff: "0.95", goal: "opcional",
                           gas: "opcional; m³ o L acumulados", gas_tariff: "opcional", water: "opcional; m³ o L acumulados", water_tariff: "opcional",
                           co2: "opcional, en % (ej. Electricity Maps)", solar_forecast: "opcional, en kWh (ej. Forecast.Solar)" },
                  need_one: "elige al menos la potencia de la red, la solar o un medidor de consumo",
                  gen: { flow: "Energía ahora", month: "Este mes", now: "Ahora", compare: "Comparación", today: "Hoy", rank: "Por aparato", power: "Potencia", last_24h: "Últimas 24 h", utility: "Gas y agua" } },
            "pt-BR" => { need_one: "escolha ao menos a potência da rede, o solar ou um medidor de consumo",
                         gen: { flow: "Energia agora", month: "Este mês", now: "Agora", compare: "Comparação", today: "Hoje", rank: "Por aparelho", power: "Potência", last_24h: "Últimas 24 h", utility: "Gás e água" } }
      fields [
        { key: "grid", label: "Potência da rede", kind: :point, hint: "W ou kW; positivo = comprando da distribuidora", filter: POWER },
        { key: "solar", label: "Geração solar", kind: :point, hint: "opcional", filter: POWER },
        { key: "battery", label: "Potência da bateria", kind: :point, hint: "opcional; positivo = descarregando", filter: POWER },
        { key: "battery_soc", label: "Carga da bateria", kind: :point, hint: "opcional, em %", filter: PERCENT },
        { key: "consumption", label: "Medidores de consumo", kind: :points, hint: "kWh ou W; vazio = a rede", filter: ENERGY },
        { key: "tariff_point", label: "Tarifa", kind: :point, hint: "helper Tarifa (tarifa branca) ou Número", filter: TARIFF },
        { key: "tariff", label: "Ou tarifa fixa (R$/kWh)", kind: :number, hint: "0,95" },
        { key: "goal", label: "Meta do mês (kWh)", kind: :number, hint: "opcional" },
        # ondaB2 (B12): o resto do painel de energia do HA.
        { key: "gas", label: "Medidor de gás", kind: :point, hint: "opcional; m³ ou L acumulados", filter: VOLUME },
        { key: "gas_tariff", label: "Tarifa do gás (por m³)", kind: :number, hint: "opcional" },
        { key: "water", label: "Medidor de água", kind: :point, hint: "opcional; m³ ou L acumulados", filter: VOLUME },
        { key: "water_tariff", label: "Tarifa da água (por m³)", kind: :number, hint: "opcional" },
        { key: "co2", label: "Parcela fóssil da rede", kind: :point, hint: "opcional, em % (ex. Electricity Maps)", filter: PERCENT },
        { key: "solar_forecast", label: "Previsão solar de hoje", kind: :point, hint: "opcional, em kWh (ex. Forecast.Solar)", filter: ENERGY }
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
          now << widget("en-flow", "energy_flow", label: text("gen.flow"), grid: grid&.id, solar: solar&.id, battery: battery&.id, battery_soc: soc&.id,
                                                  co2: one.("co2")&.id, solar_forecast: one.("solar_forecast")&.id)
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
        utility = %w[gas water].filter_map do |k|
          meter = one.(k) or next
          widget("en-#{k}", "utility", kind: k, binds: [ meter.id ], period: "month", compare: true, tariff: Widgets::Base.number(form[:"#{k}_tariff"]))
        end
        sections << section("en-util", text("gen.utility"), "beaker", utility) if utility.any?
        power = [ grid, solar, battery ].compact.map(&:id)
        sections << section("en-power", text("gen.power"), "chart-bar", [ widget("en-chart", "chart", desktop: 12, label: text("gen.last_24h"), binds: power, range: "24h") ]) if power.any?
        { "schema_version" => 1,
          "views" => [ { "id" => "energia", "title" => title, "icon" => "lightning-bolt", "sections" => sections.reject { |s| s["widgets"].empty? } } ] }
      end
    end
  end
end
