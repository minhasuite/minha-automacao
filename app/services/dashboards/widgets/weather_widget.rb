module Dashboards
  module Widgets
    # Clima (Lote 4, G11; `weather-forecast` do HA): condição e temperatura de
    # agora e a previsão por dia (padrão) ou por hora, do ponto `weather` da
    # integração Clima. `forecast`: daily | hourly | none.
    class WeatherWidget < Base
      describe type: "weather", label: "Clima", icon: "sun", required: %w[bind], params: %w[forecast], bind: true
      texts en: { "label" => "Weather", "bad_forecast" => "invalid forecast" },
            es: { "label" => "Clima", "bad_forecast" => "forecast no válido" },
            "pt-BR" => { "bad_forecast" => "forecast inválido" }

      FORECASTS = (Weather::KINDS.keys + [ "none" ]).index_with { |k| k }.freeze
      COUNT = { "daily" => 5, "hourly" => 8 }.freeze

      def self.errors(w) = w.key?("forecast") && !FORECASTS.key?(w["forecast"]) ? [ text(:bad_forecast) ] : []

      def self.data(_r, w, binds)
        point = binds.first
        return [ { "point_ids" => [], "missing" => true }, [] ] unless point&.capability == "weather"

        kind = w["forecast"] || "daily"
        list = kind == "none" ? [] : Weather.forecast(point, kind, COUNT[kind])
        [ { "point_ids" => [ point.id ], "kind" => kind, "current" => Weather.current(point), "forecast" => list,
            "icon" => Weather.icon(point.value), "updated_at" => point.address["updated_at"] }, [] ]
      end

      def self.form = "web/dashboards/widget_forms/weather"
    end
  end
end
