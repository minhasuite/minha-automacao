module Dashboards
  module Widgets
    # Comparação de consumo: hoje, esta semana e este mês contra o mesmo
    # trecho do período anterior (ontem até esta hora, semana e mês
    # passados até o mesmo ponto), com o custo pela mesma tarifa.
    class EnergyCompareWidget < Base
      ROWS = { "today" => [ "Hoje", "ontem até esta hora" ], "week" => [ "Esta semana", "semana passada até agora" ],
               "month" => [ "Este mês", "mês passado até agora" ] }.freeze

      describe type: "energy_compare", label: "Comparação de consumo", icon: "trending-up", required: %w[binds], params: %w[tariff tariff_point], binds: true

      def self.errors(w)
        w.key?("tariff") && !(w["tariff"].is_a?(Numeric) && w["tariff"] >= 0) ? [ "tariff precisa ser número maior ou igual a zero" ] : []
      end

      def self.data(r, w, binds)
        tariff = r.use(r.point(w["tariff_point"]))
        rows = ROWS.map do |period, (label, before)|
          e = Energy.new({ "period" => period, "compare" => true, "tariff" => w["tariff"] }, binds, r.site, tariff_point: tariff).call
          { "period" => period, "label" => label, "before" => before, "kwh" => e["kwh"], "previous_kwh" => e["previous_kwh"],
            "delta_pct" => e["delta_pct"], "cost" => e["cost"], "projection_kwh" => e["projection_kwh"] }
        end
        [ { "rows" => rows, "missing" => binds.none? { |p| Energy.supported?(p) }, "point_ids" => binds.map(&:id) }, [ tariff ].compact ]
      end

      def self.attrs(p, _site = nil)
        { "binds" => Array(p[:binds]).compact_blank.first(8), "tariff_point" => p[:tariff_point].presence,
          "tariff" => (number(p[:tariff]) if p[:tariff_point].blank?) }.compact
      end

      def self.form = "web/dashboards/widget_forms/energy_compare"
    end
  end
end
