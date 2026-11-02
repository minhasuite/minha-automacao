module Dashboards
  module Widgets
    # Consumo por aparelho (ranking): kWh e custo de cada aparelho no
    # período, do maior para o menor, com a fatia de cada um. Sem `binds`,
    # todos os pontos de energia/potência do local (helpers fora, para não
    # contar duas vezes um medidor por ciclo); por aparelho vale o ponto de
    # energia (kWh) e, sem ele, o de potência.
    # ponytail: uma leitura de rollups por aparelho; juntar numa consulta se o local tiver centenas.
    class EnergyBreakdownWidget < Base
      PERIODS = Energy::PERIODS.slice("today", "week", "month").freeze
      DEFAULT_LIMIT = 8

      describe type: "energy_breakdown", label: "Consumo por aparelho", icon: "chart-bar", params: %w[period limit tariff tariff_point], binds: true

      def self.errors(w)
        e = []
        e << "period inválido" if w.key?("period") && !PERIODS.key?(w["period"])
        e << "limit precisa ser de 3 a 20" if w.key?("limit") && !(w["limit"].is_a?(Integer) && w["limit"].between?(3, 20))
        e << "tariff precisa ser número maior ou igual a zero" if w.key?("tariff") && !(w["tariff"].is_a?(Numeric) && w["tariff"] >= 0)
        e
      end

      def self.data(r, w, binds)
        tariff = r.use(r.point(w["tariff_point"]))
        period = w["period"].presence_in(PERIODS.keys) || "month"
        candidates = binds.presence || r.site.points.where(helper: nil, hidden: false, disabled: false).includes(:device).to_a
        by_device = candidates.select { |p| Energy.supported?(p) }.group_by(&:device)
        rows = by_device.map do |device, pts|
          pts = pts.select { |p| Energy.energy?(p) }.presence || pts
          e = Energy.new({ "period" => period, "tariff" => w["tariff"] }, pts, r.site, tariff_point: tariff).call
          { "name" => device.name, "device_id" => device.id, "kwh" => e["kwh"], "cost" => e["cost"] }
        end
        rows = rows.select { |x| x["kwh"].positive? }.sort_by { |x| -x["kwh"] }
        total = rows.sum { |x| x["kwh"] }
        limit = w["limit"].is_a?(Integer) ? w["limit"] : DEFAULT_LIMIT
        top = rows.first(limit)
        rest = rows.drop(limit)
        top << { "name" => "Outros (#{rest.size})", "kwh" => rest.sum { |x| x["kwh"] }.round(2), "cost" => rest.filter_map { |x| x["cost"] }.sum.round(2) } if rest.any?
        top.each { |x| x["pct"] = total.positive? ? (x["kwh"] / total * 100).round(1) : 0 }
        [ { "period" => period, "period_label" => PERIODS[period], "rows" => top, "total_kwh" => total.round(2),
            "total_cost" => (rows.filter_map { |x| x["cost"] }.sum.round(2) if rows.any? { |x| x["cost"] }), "empty" => by_device.empty? }, [ tariff ].compact ]
      end

      def self.attrs(p, _site = nil)
        { "binds" => Array(p[:binds]).compact_blank.first(8).presence, "period" => p[:period].presence_in(PERIODS.keys) || "month",
          "limit" => (p[:limit].to_i.clamp(3, 20) if p[:limit].present?), "tariff_point" => p[:tariff_point].presence,
          "tariff" => (number(p[:tariff]) if p[:tariff_point].blank?) }.compact
      end

      def self.form = "web/dashboards/widget_forms/energy_breakdown"
    end
  end
end
