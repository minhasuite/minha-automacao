module Automations
  module ActionTypes
    # "Ler previsão do tempo" (Lote 4, G10/G11; `weather.get_forecasts` do HA):
    # a condição de agora e a previsão guardadas no ponto `weather` (integração
    # Clima), por dia ou por hora. Resposta: {current, forecast: [...], count,
    # today, text}; no texto `{{ clima.text }}` ou `{% for d in clima.forecast %}`,
    # na expressão `clima.today.precipitation_probability > 60`.
    class WeatherForecastAction < Base
      # Só lê o ponto de clima.
      def self.shadow_safe?(_e, _node) = true

      describe key: "weather_forecast", label: "Ler previsão do tempo", defaults: { "kind" => "daily", "count" => 3, "response_variable" => "clima" },
               fields: [ f("point", :point, "Clima", required: true, en: "Weather", es: "Clima"),
                         f("kind", :select, "Previsão", required: true, options: Weather::KINDS, en: "Forecast", es: "Pronóstico"),
                         f("count", :number, "Quantos dias ou horas (vazio = todos)", en: "How many days or hours (empty = all)", es: "Cuántos días u horas (vacío = todos)") ]
      texts en: { label: "Read weather forecast" }, es: { label: "Leer pronóstico del tiempo" }
      returns "{current: {condition, condition_text, temperature, humidity…}, forecast: [{date|time, condition, condition_text, temperature_max, temperature_min, temperature, precipitation_probability}], count, today, text}"

      def self.call(e, _path, node)
        point = e.ctx.point(node["point"]) or raise Engine::Failure, "Clima removido do local."
        raise Engine::Failure, "#{point.name} não é um ponto de clima." unless point.capability == "weather"

        list = Weather.forecast(point, node["kind"], node["count"], e.ctx.now)
        today = node["kind"] == "daily" ? list.first : Weather.forecast(point, "daily", 1, e.ctx.now).first
        current = Weather.current(point)
        text = [ ("Agora: #{current['condition_text']}, #{current['temperature']&.round}°" if current["condition"]),
                 ("Hoje: #{Weather.summary(today)}" if today) ].compact.join(". ")
        respond(e, node, { "current" => current, "forecast" => list, "count" => list.size, "today" => today, "text" => text })
        [ "Ler previsão #{point.name}", "ok", "#{list.size} #{node['kind'] == 'hourly' ? 'hora(s)' : 'dia(s)'} em #{node['response_variable']}" ]
      end
    end
  end
end
