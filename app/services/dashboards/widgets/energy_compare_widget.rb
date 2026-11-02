module Dashboards
  module Widgets
    # Comparação de consumo: hoje, esta semana e este mês contra o mesmo
    # trecho do período anterior (ontem até esta hora, semana e mês
    # passados até o mesmo ponto), com o custo pela mesma tarifa.
    class EnergyCompareWidget < Base
      ROWS = %w[today week month].freeze

      describe type: "energy_compare", label: "Comparação de consumo", icon: "trending-up", required: %w[binds], params: %w[tariff tariff_point], binds: true
      texts en: { "label" => "Usage comparison", "bad_tariff" => "tariff must be a number greater than or equal to zero", "rows.today" => "Today", "rows.today_before" => "yesterday up to this time", "rows.week" => "This week", "rows.week_before" => "last week up to now", "rows.month" => "This month", "rows.month_before" => "last month up to now" },
            es: { "label" => "Comparación de consumo", "bad_tariff" => "tariff debe ser un número mayor o igual a cero", "rows.today" => "Hoy", "rows.today_before" => "ayer hasta esta hora", "rows.week" => "Esta semana", "rows.week_before" => "la semana pasada hasta ahora", "rows.month" => "Este mes", "rows.month_before" => "el mes pasado hasta ahora" },
            "pt-BR" => { "bad_tariff" => "tariff precisa ser número maior ou igual a zero", "rows.today" => "Hoje", "rows.today_before" => "ontem até esta hora", "rows.week" => "Esta semana", "rows.week_before" => "semana passada até agora", "rows.month" => "Este mês", "rows.month_before" => "mês passado até agora" }

      def self.errors(w)
        w.key?("tariff") && !(w["tariff"].is_a?(Numeric) && w["tariff"] >= 0) ? [ text(:bad_tariff) ] : []
      end

      def self.data(r, w, binds)
        tariff = r.use(r.point(w["tariff_point"]))
        rows = ROWS.map do |period|
          label = text("rows.#{period}")
          before = text("rows.#{period}_before")
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
