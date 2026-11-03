module Weather
  module Providers
    # Met.no (catalogo, a "met" do HA): Instituto Meteorológico da Noruega,
    # grátis, sem chave, mundo todo (Locationforecast 2.0 compact). Pede um
    # User-Agent com contato; a série vem por hora (e de 6 em 6 h mais longe).
    class MetNo < Base
      describe key: "met_no", label: "Met.no (Noruega, grátis, sem chave)"
      texts en: { label: "Met.no (Norway, free, no key)", invalid: "Met.no returned an invalid response." },
            es: { label: "Met.no (Noruega, gratis, sin clave)", invalid: "Met.no devolvió una respuesta no válida." },
            "pt-BR" => { invalid: "Met.no devolveu uma resposta inválida." }

      URL = "https://api.met.no/weatherapi/locationforecast/2.0/compact".freeze
      AGENT = "MinhaAutomacao/1.0 github.com/minhasuite".freeze
      # Símbolo (sem _day/_night) → condição do formato comum.
      SYMBOLS = { "clearsky" => "sunny", "fair" => "partlycloudy", "partlycloudy" => "partlycloudy", "cloudy" => "cloudy", "fog" => "fog",
                  "lightrain" => "rainy", "rain" => "rainy", "rainshowers" => "rainy", "lightrainshowers" => "rainy", "heavyrain" => "pouring",
                  "heavyrainshowers" => "pouring", "sleet" => "snowy-rainy", "lightsleet" => "snowy-rainy", "heavysleet" => "snowy-rainy",
                  "sleetshowers" => "snowy-rainy", "snow" => "snowy", "lightsnow" => "snowy", "heavysnow" => "snowy", "snowshowers" => "snowy" }.freeze

      def self.fetch(lat:, lon:, zone:, api_key: nil)
        res = SafeHttp.get("#{URL}?lat=#{lat.to_f.round(4)}&lon=#{lon.to_f.round(4)}", headers: { "User-Agent" => AGENT }, timeout: 15)
        raise Weather::Error, "Met.no respondeu #{res.status}." unless res.status == 200

        normalize(JSON.parse(res.body), zone)
      rescue JSON::ParserError
        raise Weather::Error, text(:invalid)
      end

      def self.condition(symbol)
        base = symbol.to_s.sub(/_(day|night|polartwilight)\z/, "")
        return "lightning-rainy" if base.include?("thunder")

        cond = SYMBOLS.fetch(base, "exceptional")
        cond == "sunny" && symbol.to_s.end_with?("_night") ? "clear-night" : cond
      end

      def self.normalize(body, zone)
        tz = ActiveSupport::TimeZone[zone.to_s] || Time.zone
        series = Array(body.dig("properties", "timeseries")).map do |t|
          d = t["data"].to_h
          nxt = d["next_1_hours"] || d["next_6_hours"] || d["next_12_hours"] || {}
          { time: tz.parse(t["time"].to_s), details: d.dig("instant", "details").to_h, symbol: nxt.dig("summary", "symbol_code"),
            rain: nxt.dig("details", "precipitation_amount"), hourly: d.key?("next_1_hours") }
        end
        now = series.first || { details: {} }
        hourly = series.select { |s| s[:hourly] }.first(24).map do |s|
          { "time" => s[:time].strftime("%Y-%m-%dT%H:%M"), "condition" => condition(s[:symbol]), "temperature" => s[:details]["air_temperature"] }.compact
        end
        daily = series.group_by { |s| s[:time].to_date }.first(7).map do |date, list|
          temps = list.filter_map { |s| s[:details]["air_temperature"] }
          noon = list.min_by { |s| (s[:time].hour - 12).abs }
          { "date" => date.iso8601, "condition" => condition(noon[:symbol]&.sub(/_night\z/, "_day")), "temperature_max" => temps.max, "temperature_min" => temps.min,
            "precipitation" => list.select { |s| s[:hourly] }.sum { |s| s[:rain].to_f }.round(1) }.compact
        end
        nd = now[:details]
        current = { "condition" => condition(now[:symbol]), "temperature" => nd["air_temperature"], "humidity" => nd["relative_humidity"],
                    "wind_speed" => nd["wind_speed"] && (nd["wind_speed"] * 3.6).round(1), "precipitation" => now[:rain],
                    "is_day" => !now[:symbol].to_s.end_with?("_night") }.compact
        { "current" => current, "daily" => daily, "hourly" => hourly }
      end
    end
  end
end
