module Integrations
  # Forecast.Solar (catalogo): previsão da geração solar pela posição do local
  # e pelos painéis (inclinação, orientação e potência de pico). Grátis sem
  # chave (12 consultas por hora; lemos a cada hora); a chave paga é opcional.
  class ForecastSolarPlugin < SchemaPlugin
    describe key: "forecast_solar", title: "Forecast.Solar", icon: "sun",
             description: "Previsão da geração dos painéis solares para hoje e amanhã e a potência prevista agora, pela posição do local, para os painéis de energia."
    texts "pt-BR" => { fields: { declination: "Inclinação dos painéis (°)", azimuth: "Orientação (°)", kwp: "Potência de pico (kWp)" },
                       hints: { declination: "0 = deitado, 90 = em pé", azimuth: "0 = sul, -90 = leste, 90 = oeste, 180 = norte", kwp: "ex. 5,4" },
                       points: { power_now: "Potência prevista agora", energy_today: "Previsão solar de hoje", energy_tomorrow: "Previsão solar de amanhã",
                                 energy_remaining: "Previsão restante de hoje" },
                       no_location: "Informe a latitude e a longitude do local.", note: "No Brasil (hemisfério sul) os painéis costumam olhar para o norte: 180." },
          en: { title: "Forecast.Solar", description: "Solar panel production forecast for today and tomorrow and the expected power now, from the place's location, for the energy dashboards.",
                fields: { declination: "Panel tilt (°)", azimuth: "Orientation (°)", kwp: "Peak power (kWp)" },
                hints: { declination: "0 = flat, 90 = upright", azimuth: "0 = south, -90 = east, 90 = west, 180 = north", kwp: "e.g. 5.4" },
                points: { power_now: "Expected power now", energy_today: "Today's solar forecast", energy_tomorrow: "Tomorrow's solar forecast",
                          energy_remaining: "Remaining forecast today" },
                no_location: "Set the place's latitude and longitude.", note: "In the southern hemisphere panels usually face north: 180." },
          es: { title: "Forecast.Solar", description: "Previsión de la generación de los paneles solares para hoy y mañana y la potencia prevista ahora, por la ubicación del lugar, para los paneles de energía.",
                fields: { declination: "Inclinación de los paneles (°)", azimuth: "Orientación (°)", kwp: "Potencia pico (kWp)" },
                hints: { declination: "0 = acostado, 90 = de pie", azimuth: "0 = sur, -90 = este, 90 = oeste, 180 = norte", kwp: "ej. 5,4" },
                points: { power_now: "Potencia prevista ahora", energy_today: "Previsión solar de hoy", energy_tomorrow: "Previsión solar de mañana",
                          energy_remaining: "Previsión restante de hoy" },
                no_location: "Indica la latitud y la longitud del lugar.", note: "En el hemisferio sur los paneles suelen mirar al norte: 180." }
    field :kwp, :number, required: true
    field :declination, :number, default: 20
    field :azimuth, :number, default: 180
    field :api_key, secret: true

    class << self
      def estimate(integration)
        site = integration.site
        raise Integrations::Error, text(:no_location) unless site.latitude && site.longitude

        num = ->(k) { conf(integration, k).to_s.tr(",", ".").to_f }
        key = conf(integration, :api_key)
        path = [ key, "estimate", site.latitude.to_f.round(4), site.longitude.to_f.round(4), num.(:declination).round, num.(:azimuth).round, num.(:kwp) ].compact.join("/")
        res = SafeHttp.get("https://api.forecast.solar/#{path}", timeout: 15)
        body = JSON.parse(res.body)
        raise Integrations::Error, "Forecast.Solar: #{body.dig('message', 'text') || res.status}" unless res.status == 200

        body["result"].to_h
      rescue SafeHttp::Error, JSON::ParserError => e
        raise Integrations::Error, "Forecast.Solar: #{e.message}"
      end

      def entries(integration)
        estimate(integration)
        [ entry(id: "forecast_solar:#{integration.id}", name: integration.name, category: "Previsão solar", poll_s: 3600,
                points: [ point("power_now", unit: "W", device_class: "power", state_class: "measurement"),
                          point("energy_today", unit: "kWh", device_class: "energy"), point("energy_remaining", unit: "kWh", device_class: "energy"),
                          point("energy_tomorrow", unit: "kWh", device_class: "energy") ]) ]
      end

      def read(device, now = Time.current)
        r = estimate(device.integration)
        zone = ActiveSupport::TimeZone[device.site.timezone] || Time.zone
        local = now.in_time_zone(zone)
        watts = r["watts"].to_h.transform_keys { |k| zone.parse(k) }
        day = r["watt_hours_day"].to_h
        before = watts.keys.select { |t| t <= local }.max
        today = local.to_date
        wh = r["watt_hours"].to_h.transform_keys { |k| zone.parse(k) }
        { "power_now" => (before && before.to_date == today ? watts[before] : 0),
          "energy_today" => (day[today.iso8601].to_f / 1000).round(2), "energy_tomorrow" => (day[(today + 1).iso8601].to_f / 1000).round(2),
          "energy_remaining" => ((day[today.iso8601].to_f - (wh.select { |t, _| t.to_date == today && t <= local }.values.max || 0)) / 1000).round(2) }
      end
    end
  end
end
