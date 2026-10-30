# Clima (Lote 4, G11): previsão do tempo de qualquer provedor, sem nada fixo
# de lugar. Provedor = classe em app/services/weather/providers/ (herda de
# `Weather::Providers::Base`) + nome em `PROVIDERS`; a integração
# (`Integrations::WeatherPlugin`), a ação "Ler previsão do tempo" e o widget
# `weather` só falam com o formato comum abaixo, nunca com o provedor.
#
# Formato comum (o que `fetch` devolve):
#   current: {condition, temperature, apparent_temperature, humidity, wind_speed,
#             precipitation, precipitation_probability, is_day}
#   daily:   [{date, condition, temperature_max, temperature_min, precipitation_probability, precipitation}]
#   hourly:  [{time, condition, temperature, precipitation_probability}]
# Chave ausente = o provedor não informa (o ponto daquela medida não nasce).
module Weather
  class Error < StandardError; end

  # Ordem = ordem no formulário; o primeiro é o padrão.
  PROVIDERS = %w[OpenMeteo].freeze

  # Condição (mesmos nomes do HA) → [rótulo, ícone].
  CONDITIONS = {
    "sunny" => [ "Ensolarado", "sun" ], "clear-night" => [ "Céu limpo", "moon" ], "partlycloudy" => [ "Parcialmente nublado", "cloud" ],
    "cloudy" => [ "Nublado", "cloud" ], "fog" => [ "Neblina", "cloud" ], "rainy" => [ "Chuva", "cloud-rain" ],
    "pouring" => [ "Chuva forte", "cloud-rain" ], "lightning-rainy" => [ "Tempestade", "lightning-bolt" ],
    "snowy" => [ "Neve", "cloud" ], "snowy-rainy" => [ "Chuva e neve", "cloud-rain" ], "hail" => [ "Granizo", "cloud-rain" ],
    "windy" => [ "Ventania", "cloud" ], "exceptional" => [ "Fora do comum", "exclamation-circle" ]
  }.freeze

  # Medidas do `current` que viram ponto `measure`: campo → [nome, unidade, device_class].
  MEASURES = {
    "temperature" => [ "Temperatura", "°C", "temperature" ], "apparent_temperature" => [ "Sensação térmica", "°C", "temperature" ],
    "humidity" => [ "Umidade", "%", "humidity" ], "wind_speed" => [ "Vento", "km/h", nil ],
    "precipitation_probability" => [ "Chance de chuva hoje", "%", nil ]
  }.freeze

  KINDS = { "daily" => "Por dia", "hourly" => "Por hora" }.freeze

  module_function

  def providers = PROVIDERS.map { |name| Providers.const_get(name) }
  def provider(key) = providers.find { |p| p.key == key.to_s } || providers.first
  def choices = providers.to_h { |p| [ p.key, p.label ] }

  def label(condition) = CONDITIONS.dig(condition.to_s, 0) || condition.to_s
  def icon(condition) = CONDITIONS.dig(condition.to_s, 1) || "sun"

  # Grava a leitura no aparelho virtual: o ponto `weather` (valor = condição,
  # agora e previsão no endereço) e um `measure` por medida informada.
  def store!(device, data, now = Time.current)
    current = data["current"].to_h
    main = point(device, "condition") { { name: "Clima", capability: "weather", options: CONDITIONS.keys, history: "on_change" } }
    main.update!(address: main.address.merge("current" => current, "daily" => Array(data["daily"]), "hourly" => Array(data["hourly"]),
                                             "updated_at" => now.iso8601))
    main.report!(current["condition"])
    MEASURES.each do |field, (name, unit, device_class)|
      next if current[field].nil?

      point(device, field) { { name: name, capability: "measure", unit: unit, device_class: device_class, history: "on_change" } }.report!(current[field])
    end
    main
  end

  def point(device, field)
    device.points.find_by("address->>'field' = ?", field) ||
      device.points.create!(yield.merge(site: device.site, address: { "field" => field }, key: Integrations.unique_key(device.site, device, yield[:name])))
  end

  # Previsão guardada no ponto: as próximas `count` entradas (dia ou hora) a partir de agora.
  def forecast(point, kind = "daily", count = nil, now = Time.current)
    zone = ActiveSupport::TimeZone[point.site.timezone]
    today = now.in_time_zone(zone).to_date.iso8601
    hourly = kind == "hourly"
    list = Array(point.address[hourly ? "hourly" : "daily"]).select do |x|
      hourly ? (t = zone.parse(x["time"].to_s)) && t >= now - 1.hour : x["date"].to_s >= today
    end
    list = list.first(count.to_i) if count.to_i.positive?
    list.map { |x| x.merge("condition_text" => label(x["condition"])) }
  end

  def current(point) = point.address["current"].to_h.then { |c| c.merge("condition_text" => label(c["condition"])) }

  # "Hoje: Chuva, 18° a 25°, 80% de chance de chuva" (resumo para texto e voz).
  def summary(day)
    return "" unless day

    parts = [ label(day["condition"]) ]
    parts << "#{day['temperature_min']&.round}° a #{day['temperature_max']&.round}°" if day["temperature_max"]
    parts << "#{day['precipitation_probability']}% de chance de chuva" if day["precipitation_probability"]
    parts.join(", ")
  end
end
