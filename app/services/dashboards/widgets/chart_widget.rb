module Dashboards
  module Widgets
    # Gráfico (F5): linhas dos pontos na mesma escala; a tela busca o histórico.
    class ChartWidget < Base
      describe type: "chart", label: "Gráfico", icon: "chart-bar", required: %w[binds], params: %w[range], binds: true

      def self.data(r, w, binds) = GroupWidget.data(r, w, binds)
      def self.attrs(p, site = nil) = super.merge("range" => p[:range].presence || "24h")
      def self.form = "web/dashboards/widget_forms/chart"
    end
  end
end
