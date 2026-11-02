module Dashboards
  module Widgets
    # Consumo e custo (F9): período, dia de corte, tarifa (número ou ponto),
    # meta e comparação; o cálculo é do `Dashboards::Energy`.
    class EnergyWidget < Base
      describe type: "energy", label: "Consumo e custo", required: %w[binds], params: %w[period cycle_day tariff tariff_point goal compare], binds: true
      texts en: { "label" => "Usage and cost", "bad_period" => "invalid period", "bad_cycle" => "cycle_day must be from 1 to 28", "bad_tariff" => "tariff must be a number greater than or equal to zero", "bad_tariff_point" => "tariff_point must be text", "bad_goal" => "goal must be a number greater than zero", "bad_compare" => "compare must be true or false" },
            es: { "label" => "Consumo y costo", "bad_period" => "period no válido", "bad_cycle" => "cycle_day debe ser de 1 a 28", "bad_tariff" => "tariff debe ser un número mayor o igual a cero", "bad_tariff_point" => "tariff_point debe ser texto", "bad_goal" => "goal debe ser un número mayor que cero", "bad_compare" => "compare debe ser true o false" },
            "pt-BR" => { "bad_period" => "period inválido", "bad_cycle" => "cycle_day precisa ser de 1 a 28", "bad_tariff" => "tariff precisa ser número maior ou igual a zero", "bad_tariff_point" => "tariff_point precisa ser texto", "bad_goal" => "goal precisa ser número maior que zero", "bad_compare" => "compare precisa ser true ou false" }

      def self.errors(w)
        e = []
        e << text(:bad_period) if w.key?("period") && !Energy::PERIODS.key?(w["period"])
        e << text(:bad_cycle) if w.key?("cycle_day") && !(w["cycle_day"].is_a?(Integer) && w["cycle_day"].between?(1, 28))
        e << text(:bad_tariff) if w.key?("tariff") && !(w["tariff"].is_a?(Numeric) && w["tariff"] >= 0)
        e << text(:bad_tariff_point) if w.key?("tariff_point") && !w["tariff_point"].is_a?(String)
        e << text(:bad_goal) if w.key?("goal") && !(w["goal"].is_a?(Numeric) && w["goal"].positive?)
        e << text(:bad_compare) if w.key?("compare") && ![ true, false ].include?(w["compare"])
        e
      end

      def self.data(r, w, binds)
        tariff = r.use(r.point(w["tariff_point"]))
        [ Energy.new(w, binds, r.site, tariff_point: tariff).call, [ tariff ].compact ]
      end

      def self.attrs(p, _site = nil)
        a = { "binds" => Array(p[:binds]).compact_blank.first(8), "period" => p[:period].presence_in(Energy::PERIODS.keys) || "month",
              "tariff_point" => p[:tariff_point].presence, "goal" => number(p[:goal]), "compare" => p[:compare] == "1" || nil }
        a["cycle_day"] = p[:cycle_day].to_i.clamp(1, 28) if a["period"] == "cycle"
        a["tariff"] = number(p[:tariff]) unless a["tariff_point"]
        a
      end

      def self.form = "web/dashboards/widget_forms/energy"
    end
  end
end
