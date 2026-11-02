module Weather
  module Providers
    # Open-Meteo (open-meteo.com): grátis, sem chave, modelos de vários
    # serviços nacionais. Agora, 7 dias e as próximas 24 horas numa chamada.
    class OpenMeteo < Base
      describe key: "open_meteo", label: "Open-Meteo (grátis, sem chave)"
      texts en: { label: "Open-Meteo (free, no key)", invalid: "Open-Meteo returned an invalid response." },
            es: { label: "Open-Meteo (gratis, sin clave)", invalid: "Open-Meteo devolvió una respuesta no válida." },
            "pt-BR" => { invalid: "Open-Meteo devolveu uma resposta inválida." }

      URL = "https://api.open-meteo.com/v1/forecast".freeze
      # Código WMO → condição do formato comum.
      CODES = {
        0 => "sunny", 1 => "sunny", 2 => "partlycloudy", 3 => "cloudy", 45 => "fog", 48 => "fog",
        51 => "rainy", 53 => "rainy", 55 => "rainy", 56 => "snowy-rainy", 57 => "snowy-rainy",
        61 => "rainy", 63 => "rainy", 65 => "pouring", 66 => "snowy-rainy", 67 => "snowy-rainy",
        71 => "snowy", 73 => "snowy", 75 => "snowy", 77 => "snowy", 80 => "rainy", 81 => "rainy", 82 => "pouring",
        85 => "snowy", 86 => "snowy", 95 => "lightning-rainy", 96 => "hail", 99 => "hail"
      }.freeze

      def self.fetch(lat:, lon:, zone:, api_key: nil)
        query = { latitude: lat, longitude: lon, timezone: zone, forecast_days: 7, forecast_hours: 24, wind_speed_unit: "kmh",
                  current: "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,precipitation,weather_code,is_day",
                  hourly: "temperature_2m,precipitation_probability,weather_code",
                  daily: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum" }
        res = SafeHttp.get("#{URL}?#{query.to_query}", timeout: 15)
        raise Weather::Error, "Open-Meteo respondeu #{res.status}." unless res.status == 200

        normalize(JSON.parse(res.body))
      rescue JSON::ParserError
        raise Weather::Error, text(:invalid)
      end

      def self.normalize(body)
        c = body["current"].to_h
        d = body["daily"].to_h
        h = body["hourly"].to_h
        daily = Array(d["time"]).each_with_index.map do |date, i|
          { "date" => date, "condition" => condition(d["weather_code"]&.[](i)), "temperature_max" => d["temperature_2m_max"]&.[](i),
            "temperature_min" => d["temperature_2m_min"]&.[](i), "precipitation_probability" => d["precipitation_probability_max"]&.[](i),
            "precipitation" => d["precipitation_sum"]&.[](i) }.compact
        end
        hourly = Array(h["time"]).each_with_index.map do |time, i|
          { "time" => time, "condition" => condition(h["weather_code"]&.[](i)), "temperature" => h["temperature_2m"]&.[](i),
            "precipitation_probability" => h["precipitation_probability"]&.[](i) }.compact
        end
        day = c["is_day"] != 0
        today = daily.find { |x| x["date"] == c["time"].to_s[0, 10] } || daily.first
        current = { "condition" => condition(c["weather_code"], day: day), "temperature" => c["temperature_2m"],
                    "apparent_temperature" => c["apparent_temperature"], "humidity" => c["relative_humidity_2m"],
                    "wind_speed" => c["wind_speed_10m"], "precipitation" => c["precipitation"],
                    "precipitation_probability" => today&.dig("precipitation_probability"), "is_day" => day }.compact
        { "current" => current, "daily" => daily, "hourly" => hourly }
      end

      def self.condition(code, day: true)
        cond = CODES.fetch(code.to_i, "exceptional") unless code.nil?
        cond == "sunny" && !day ? "clear-night" : cond
      end
    end
  end
end
