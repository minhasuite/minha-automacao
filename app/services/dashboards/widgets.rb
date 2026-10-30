module Dashboards
  # Widgets como plugins (Lote 4), no padrão de Integrations::PLUGINS: tipo
  # novo = classe em app/services/dashboards/widgets/ (herda de `Base`) + nome
  # em `PLUGINS` + partial `web/dashboards/widgets/_<tipo>` (e, se tiver campos
  # próprios no editor, `web/dashboards/widget_forms/_<tipo>`). O Schema, o
  # Resolver, o editor e a API perguntam ao plugin; os tipos da F5 continuam
  # em `Schema::WIDGETS`.
  module Widgets
    PLUGINS = %w[MarkdownWidget WeatherWidget].freeze

    module_function

    def plugins = PLUGINS.map { |name| const_get(name) }
    def [](type) = plugins.find { |p| p.type == type.to_s }

    class Base
      class << self
        attr_reader :type, :label, :icon

        # required: props obrigatórias; params: campos do editor (texto simples);
        # bind: true = o editor mostra o seletor de um ponto.
        def describe(type:, label:, icon: "cube", required: [], params: [], bind: false)
          @type = type
          @label = label
          @icon = icon
          @required = required.freeze
          @params = params.freeze
          @bind = bind
        end

        def required = @required || []
        def params = @params || []
        def bind? = @bind == true

        # Mensagens além das props obrigatórias (sem o "widget x:" na frente).
        def errors(_w) = []

        # → [data, pontos extras de que o widget depende]. `r` = Resolver
        # (`r.point(ref)`, `r.site`); `binds` = pontos de bind/binds já lidos.
        def data(_r, _w, binds) = [ { "point_ids" => binds.map(&:id) }, [] ]

        # Formulário do editor → props do widget (o `type`, `label`, `span` e
        # `visible_if` são do editor).
        def attrs(p) = { "bind" => (p[:bind].presence if bind?) }.merge(params.to_h { |k| [ k, p[k].presence ] })

        def partial = "web/dashboards/widgets/#{type}"
        def form = nil
      end
    end
  end
end
