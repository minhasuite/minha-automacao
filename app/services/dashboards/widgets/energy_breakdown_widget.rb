module Dashboards
  module Widgets
    # Consumo por aparelho (ranking): kWh e custo de cada aparelho no
    # período, do maior para o menor, com a fatia de cada um. Sem `binds`,
    # todos os pontos de energia/potência do local (helpers fora, para não
    # contar duas vezes um medidor por ciclo); por aparelho vale o ponto de
    # energia (kWh) e, sem ele, o de potência.
    # Sem tarifa no widget vale a do local (tela Energia, `EnergyUse`).
    # `metric: "cost"` ordena e mostra pelo custo ("Gasto do mês por aparelho").
    # ponytail: uma leitura de rollups por aparelho; juntar numa consulta se o local tiver centenas.
    class EnergyBreakdownWidget < Base
      PERIODS = Energy::PERIODS.slice("today", "week", "month").freeze
      DEFAULT_LIMIT = 8

      describe type: "energy_breakdown", label: "Consumo por aparelho", icon: "chart-bar", params: %w[period limit tariff tariff_point metric], binds: true
      METRICS = %w[kwh cost].freeze
      texts en: { "label" => "Usage by device", "bad_period" => "invalid period", "bad_limit" => "limit must be from 3 to 20", "bad_tariff" => "tariff must be a number greater than or equal to zero",
                  "bad_metric" => "metric must be kwh or cost" },
            es: { "label" => "Consumo por aparato", "bad_period" => "period no válido", "bad_limit" => "limit debe ser de 3 a 20", "bad_tariff" => "tariff debe ser un número mayor o igual a cero",
                  "bad_metric" => "metric debe ser kwh o cost" },
            "pt-BR" => { "bad_period" => "period inválido", "bad_limit" => "limit precisa ser de 3 a 20", "bad_tariff" => "tariff precisa ser número maior ou igual a zero",
                         "bad_metric" => "metric precisa ser kwh ou cost" }

      def self.errors(w)
        e = []
        e << text(:bad_period) if w.key?("period") && !PERIODS.key?(w["period"])
        e << text(:bad_limit) if w.key?("limit") && !(w["limit"].is_a?(Integer) && w["limit"].between?(3, 20))
        e << text(:bad_tariff) if w.key?("tariff") && !(w["tariff"].is_a?(Numeric) && w["tariff"] >= 0)
        e << text(:bad_metric) if w.key?("metric") && !METRICS.include?(w["metric"])
        e
      end

      def self.data(r, w, binds)
        own = w["tariff_point"].present? || w.key?("tariff")
        tariff = r.use(r.point(own ? w["tariff_point"] : EnergyUse.tariff_point(r.site)&.id))
        fixed = own ? w["tariff"] : EnergyUse.tariff(r.site)
        by_cost = w["metric"] == "cost"
        period = w["period"].presence_in(PERIODS.keys) || "month"
        candidates = binds.presence || r.site.points.where(helper: nil, hidden: false, disabled: false).includes(:device).to_a
        by_device = candidates.select { |p| Energy.supported?(p) }.group_by(&:device)
        rows = by_device.map do |device, pts|
          pts = pts.select { |p| Energy.energy?(p) }.presence || pts
          e = Energy.new({ "period" => period, "tariff" => fixed }, pts, r.site, tariff_point: tariff).call
          { "name" => device.name, "device_id" => device.id, "kwh" => e["kwh"], "cost" => e["cost"] }
        end
        rows = rows.select { |x| x["kwh"].positive? }.sort_by { |x| -(by_cost ? x["cost"].to_f : x["kwh"]) }
        total = rows.sum { |x| x["kwh"] }
        limit = w["limit"].is_a?(Integer) ? w["limit"] : DEFAULT_LIMIT
        top = rows.first(limit)
        rest = rows.drop(limit)
        top << { "name" => "Outros (#{rest.size})", "kwh" => rest.sum { |x| x["kwh"] }.round(2), "cost" => rest.filter_map { |x| x["cost"] }.sum.round(2) } if rest.any?
        top.each { |x| x["pct"] = total.positive? ? (x["kwh"] / total * 100).round(1) : 0 }
        [ { "period" => period, "period_label" => I18n.t("dashboards.periods.#{period}"), "rows" => top, "total_kwh" => total.round(2),
            "total_cost" => (rows.filter_map { |x| x["cost"] }.sum.round(2) if rows.any? { |x| x["cost"] }), "empty" => by_device.empty?,
            "metric" => (by_cost && rows.any? { |x| x["cost"] } ? "cost" : "kwh") }, [ tariff ].compact ]
      end

      def self.attrs(p, _site = nil)
        { "binds" => Array(p[:binds]).compact_blank.first(8).presence, "period" => p[:period].presence_in(PERIODS.keys) || "month",
          "limit" => (p[:limit].to_i.clamp(3, 20) if p[:limit].present?), "tariff_point" => p[:tariff_point].presence,
          "tariff" => (number(p[:tariff]) if p[:tariff_point].blank?), "metric" => p[:metric].presence_in(METRICS) }.compact
      end

      def self.form = "web/dashboards/widget_forms/energy_breakdown"
    end
  end
end
