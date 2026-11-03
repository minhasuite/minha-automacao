module Dashboards
  # Widgets como plugins (Lote 4), no padrão de Integrations::PLUGINS: tipo
  # novo = classe em app/services/dashboards/widgets/ (herda de `Base`) + nome
  # em `PLUGINS` + partial `web/dashboards/widgets/_<tipo>` (e, se tiver campos
  # próprios no editor, `web/dashboards/widget_forms/_<tipo>`). O Schema, o
  # Resolver, o editor, o painel automático e a API perguntam ao plugin; os
  # tipos da F5 também são plugins. A ordem é a do seletor de tipo no editor.
  module Widgets
    PLUGINS = %w[TileWidget GroupWidget StatWidget GaugeWidget ChartWidget QueryListWidget AreaCardWidget SceneBarWidget
                 AlertsWidget CameraWidget VacuumWidget EnergyWidget HeadingWidget MarkdownWidget WeatherWidget MediaWidget RemoteWidget
                 PeopleWidget AlarmWidget FloorplanWidget EnergyFlowWidget EnergyBreakdownWidget EnergyCompareWidget MapWidget CustomCardWidget].freeze

    module_function

    def plugins = PLUGINS.map { |name| const_get(name) }
    def [](type) = plugins.find { |p| p.type == type.to_s }
    # Pacote 1: widget que o painel automático usa para a capacidade (`describe auto:`).
    def for_capability(cap) = plugins.find { |p| p.auto.include?(cap.to_s) }
    # Painel automático: o widget próprio do ponto (câmera, robô, mídia...), ou nil (vira `tile`).
    def auto_widget(point, id) = plugins.lazy.filter_map { |p| p.auto_widget(point, id) }.first

    class Base
      extend PluginTexts
      translates :label

      class << self
        attr_reader :type, :icon

        # required: props obrigatórias; params: campos do editor (texto simples);
        # bind: true = o editor mostra o seletor de um ponto; binds: true = o
        # de vários (até 8).
        def describe(type:, label:, icon: "cube", required: [], params: [], bind: false, binds: false, auto: [])
          @type = type
          @label = label
          @icon = icon
          @required = required.freeze
          @params = params.freeze
          @bind = bind
          @binds = binds
          @auto = auto.freeze
        end

        def required = @required || []
        def params = @params || []
        def bind? = @bind == true
        def binds? = @binds == true
        def auto = @auto || []

        # Campos do formulário para o strong params do editor (lista = `{ "x" => [] }`).
        def permit = params

        # Mensagens além das props obrigatórias (sem o "widget x:" na frente).
        def errors(_w) = []

        # → [data, pontos extras de que o widget depende]. `r` = Resolver
        # (`r.point(ref)`, `r.site`, `r.role`, `r.points`, `r.query(q)`,
        # `r.definition`); `binds` = pontos de bind/binds já lidos. Ponto que
        # o widget desenha entra no `points` do JSON por `r.use(p)`.
        def data(_r, _w, binds) = [ { "point_ids" => binds.map(&:id) }, [] ]

        # Formulário do editor → props do widget (o `type`, `label`, `span` e
        # `visible_if` são do editor). `site` = o local do painel.
        def attrs(p, _site = nil)
          { "bind" => (p[:bind].presence if bind?), "binds" => (Array(p[:binds]).compact_blank.first(8) if binds?) }
            .merge(params.to_h { |k| [ k, p[k].presence ] }).compact
        end

        # Painel automático (Pacote 1, `describe auto:`): o widget para o ponto, ou nil.
        def auto_widget(point, id)
          { "id" => id, "type" => type, "bind" => point.id, "span" => { "mobile" => 12, "tablet" => 12, "desktop" => 6 } } if auto.include?(point.capability)
        end

        # Número do formulário ("0,95" → 0.95; inteiro sem ".0"); vazio = nil.
        def number(v)
          n = Float(v.to_s.tr(",", "."), exception: false) if v.present?
          n && n % 1 == 0 ? n.to_i : n
        end

        # Irmão `color` do aparelho do ponto (lâmpada colorida): o widget acende na cor real.
        def color_point(r, point)
          return unless point&.capability.in?(%w[onoff dimmer])

          r.points.find { |p| p.device_id == point.device_id && p.capability == "color" && !p.disabled }
        end

        # ondaB2: o widget aceita tap/hold/double_tap_action (o editor mostra os campos).
        def gestures? = false

        def partial = "web/dashboards/widgets/#{type}"
        def form = nil
      end
    end
  end
end
