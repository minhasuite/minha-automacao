module Dashboards
  module Widgets
    # Medidor em arco (F5): faixa do widget, senão a do ponto, senão 0–100.
    class GaugeWidget < Base
      describe type: "gauge", label: "Medidor", icon: "clock", required: %w[bind], params: %w[min max], bind: true

      def self.data(_r, w, binds)
        point = binds.first
        min = (w["min"] || point&.min || 0).to_f
        max = (w["max"] || point&.max || 100).to_f
        v = point&.value
        ratio = v.is_a?(Numeric) && max > min ? ((v - min) / (max - min)).clamp(0, 1).round(4) : nil
        [ { "point_ids" => [ point&.id ].compact, "min" => min, "max" => max, "ratio" => ratio }, [] ]
      end

      def self.attrs(p, site = nil) = super.merge("min" => number(p[:min]), "max" => number(p[:max])).compact
      def self.form = "web/dashboards/widget_forms/gauge"
    end
  end
end
