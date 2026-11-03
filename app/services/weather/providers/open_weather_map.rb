module Weather
  module Providers
    # OpenWeatherMap (catalogo): plano grátis (API 2.5: tempo de agora e
    # previsão de 5 dias de 3 em 3 horas) com a chave da conta do dono.
    class OpenWeatherMap < Base
      describe key: "openweathermap", label: "OpenWeatherMap (chave grátis)", needs_key: true
      texts en: { label: "OpenWeatherMap (free key)", invalid: "OpenWeatherMap returned an invalid response.", bad_key: "OpenWeatherMap refused the key." },
            es: { label: "OpenWeatherMap (clave gratis)", invalid: "OpenWeatherMap devolvió una respuesta no válida.", bad_key: "OpenWeatherMap rechazó la clave." },
            "pt-BR" => { invalid: "OpenWeatherMap devolveu uma resposta inválida.", bad_key: "O OpenWeatherMap recusou a chave." }

      URL = "https://api.openweathermap.org/data/2.5".freeze

      def self.get(path, query)
        res = SafeHttp.get("#{URL}/#{path}?#{query.to_query}", timeout: 15)
        raise Weather::Error, text(:bad_key) if res.status == 401
        raise Weather::Error, "OpenWeatherMap respondeu #{res.status}." unless res.status == 200

        JSON.parse(res.body)
      rescue JSON::ParserError
        raise Weather::Error, text(:invalid)
      end

      def self.fetch(lat:, lon:, zone:, api_key: nil)
        q = { lat: lat, lon: lon, appid: api_key, units: "metric" }
        normalize(get("weather", q), get("forecast", q), zone)
      end

      # Código da condição (https://openweathermap.org/weather-conditions) → formato comum.
      def self.condition(id, day: true)
        id = id.to_i
        case id
        when 200..299 then "lightning-rainy"
        when 502..504, 522 then "pouring"
        when 511, 611..616 then "snowy-rainy"
        when 300..599 then "rainy"
        when 600..699 then "snowy"
        when 781 then "exceptional"
        when 700..799 then "fog"
        when 800 then day ? "sunny" : "clear-night"
        when 801, 802 then "partlycloudy"
        else "cloudy"
        end
      end

      def self.normalize(now, forecast, zone)
        tz = ActiveSupport::TimeZone[zone.to_s] || Time.zone
        list = Array(forecast["list"]).map { |x| x.merge("at" => Time.zone.at(x["dt"].to_i).in_time_zone(tz)) }
        hourly = list.first(8).map do |x|
          { "time" => x["at"].strftime("%Y-%m-%dT%H:%M"), "condition" => condition(x.dig("weather", 0, "id"), day: x.dig("sys", "pod") != "n"),
            "temperature" => x.dig("main", "temp"), "precipitation_probability" => (x["pop"].to_f * 100).round }
        end
        daily = list.group_by { |x| x["at"].to_date }.first(6).map do |date, xs|
          noon = xs.min_by { |x| (x["at"].hour - 12).abs }
          { "date" => date.iso8601, "condition" => condition(noon.dig("weather", 0, "id")), "temperature_max" => xs.map { |x| x.dig("main", "temp_max") }.compact.max,
            "temperature_min" => xs.map { |x| x.dig("main", "temp_min") }.compact.min, "precipitation_probability" => (xs.map { |x| x["pop"].to_f }.max * 100).round,
            "precipitation" => xs.sum { |x| x.dig("rain", "3h").to_f }.round(1) }.compact
        end
        sys = now["sys"].to_h
        day = now["dt"].to_i.between?(sys["sunrise"].to_i, sys["sunset"].to_i)
        current = { "condition" => condition(now.dig("weather", 0, "id"), day: day), "temperature" => now.dig("main", "temp"),
                    "apparent_temperature" => now.dig("main", "feels_like"), "humidity" => now.dig("main", "humidity"),
                    "wind_speed" => now.dig("wind", "speed") && (now.dig("wind", "speed") * 3.6).round(1), "precipitation" => now.dig("rain", "1h"),
                    "precipitation_probability" => daily.first&.dig("precipitation_probability"), "is_day" => day }.compact
        { "current" => current, "daily" => daily, "hourly" => hourly }
      end
    end
  end
end
