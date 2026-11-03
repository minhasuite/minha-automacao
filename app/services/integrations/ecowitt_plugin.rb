module Integrations
  # Ecowitt (catalogo): estações e sensores Ecowitt (GW1000/GW2000, WS90,
  # WH31…) pelo "Customized upload" do gateway: ele manda as leituras para o
  # MA (POST no formato Ecowitt, unidades imperiais) em `/mensageiros/<id>`
  # (o webhook genérico de integração). O gateway é reconhecido pela PASSKEY
  # (MD5 do MAC) do primeiro envio; outra PASSKEY depois disso é recusada.
  # Os pontos nascem conforme os sensores aparecem no envio.
  class EcowittPlugin < SchemaPlugin
    describe key: "ecowitt", title: "Ecowitt", icon: "cloud-rain",
             description: "Estações meteorológicas e sensores Ecowitt pelo envio do gateway (sem nuvem): temperatura, umidade, pressão, vento, chuva, sol, UV, solo e bateria."
    texts "pt-BR" => { points: { temperature_in: "Temperatura interna", humidity_in: "Umidade interna", wind_gust: "Rajada", wind_dir: "Direção do vento",
                                 rain_rate: "Chuva agora", rain_day: "Chuva hoje", solar: "Radiação solar", uv: "Índice UV", channel_temperature: "Temperatura %{n}",
                                 channel_humidity: "Umidade %{n}", soil: "Umidade do solo %{n}", pm25: "PM2,5 %{n}" },
                       setup: "No app WS View Plus (ou na página do gateway): Weather Services → Customized → protocolo Ecowitt, servidor = IP deste servidor, porta = a do Minha Automação e caminho abaixo.",
                       path: "Caminho", passkey: "Gateway (PASSKEY)", waiting: "esperando o primeiro envio", last: "Último envio", wrong_gateway: "PASSKEY diferente da do gateway cadastrado." },
          en: { title: "Ecowitt", description: "Ecowitt weather stations and sensors through the gateway's upload (no cloud): temperature, humidity, pressure, wind, rain, sun, UV, soil and battery.",
                points: { temperature_in: "Indoor temperature", humidity_in: "Indoor humidity", wind_gust: "Gust", wind_dir: "Wind direction", rain_rate: "Rain now",
                          rain_day: "Rain today", solar: "Solar radiation", uv: "UV index", channel_temperature: "Temperature %{n}", channel_humidity: "Humidity %{n}",
                          soil: "Soil moisture %{n}", pm25: "PM2.5 %{n}" },
                setup: "In the WS View Plus app (or the gateway's page): Weather Services → Customized → Ecowitt protocol, server = this server's IP, port = Minha Automação's port and the path below.",
                path: "Path", passkey: "Gateway (PASSKEY)", waiting: "waiting for the first upload", last: "Last upload", wrong_gateway: "PASSKEY differs from the registered gateway's." },
          es: { title: "Ecowitt", description: "Estaciones meteorológicas y sensores Ecowitt mediante el envío del gateway (sin nube): temperatura, humedad, presión, viento, lluvia, sol, UV, suelo y batería.",
                points: { temperature_in: "Temperatura interior", humidity_in: "Humedad interior", wind_gust: "Ráfaga", wind_dir: "Dirección del viento", rain_rate: "Lluvia ahora",
                          rain_day: "Lluvia hoy", solar: "Radiación solar", uv: "Índice UV", channel_temperature: "Temperatura %{n}", channel_humidity: "Humedad %{n}",
                          soil: "Humedad del suelo %{n}", pm25: "PM2,5 %{n}" },
                setup: "En la app WS View Plus (o en la página del gateway): Weather Services → Customized → protocolo Ecowitt, servidor = IP de este servidor, puerto = el de Minha Automação y la ruta de abajo.",
                path: "Ruta", passkey: "Gateway (PASSKEY)", waiting: "esperando el primer envío", last: "Último envío", wrong_gateway: "PASSKEY distinta de la del gateway registrado." }

    F = ->(v) { ((v.to_f - 32) * 5 / 9).round(1) }
    MPH = ->(v) { (v.to_f * 1.609344).round(1) }
    INCH = ->(v) { (v.to_f * 25.4).round(1) }
    # Campo do envio → [campo do ponto, conversão, opções].
    FIELDS = {
      "tempf" => [ "temperature", F, { unit: "°C", device_class: "temperature" } ], "humidity" => [ "humidity", nil, { unit: "%", device_class: "humidity" } ],
      "tempinf" => [ "temperature_in", F, { unit: "°C", device_class: "temperature" } ], "humidityin" => [ "humidity_in", nil, { unit: "%", device_class: "humidity" } ],
      "baromrelin" => [ "pressure", ->(v) { (v.to_f * 33.8639).round(1) }, { unit: "hPa", device_class: "pressure" } ],
      "windspeedmph" => [ "wind_speed", MPH, { unit: "km/h" } ], "windgustmph" => [ "wind_gust", MPH, { unit: "km/h" } ], "winddir" => [ "wind_dir", nil, { unit: "°" } ],
      "rainratein" => [ "rain_rate", INCH, { unit: "mm/h" } ], "dailyrainin" => [ "rain_day", INCH, { unit: "mm" } ],
      "solarradiation" => [ "solar", nil, { unit: "W/m²" } ], "uv" => [ "uv", nil, {} ]
    }.freeze
    # Sensores numerados (temp1f, humidity2, soilmoisture3, pm25_ch1).
    CHANNELS = [ [ /\Atemp(\d)f\z/, "channel_temperature", F, { unit: "°C", device_class: "temperature" } ],
                 [ /\Ahumidity(\d)\z/, "channel_humidity", nil, { unit: "%", device_class: "humidity" } ],
                 [ /\Asoilmoisture(\d)\z/, "soil", nil, { unit: "%" } ], [ /\Apm25_ch(\d)\z/, "pm25", nil, { unit: "µg/m³" } ] ].freeze

    class << self
      def login(integration, form)
        integration.settings = integration.settings.merge("account" => title)
        integration.save!
        outcome(:panel, integration: integration)
      end

      def entries(_integration) = [] # os aparelhos nascem do primeiro envio do gateway
      def custom_sync? = true
      def sync!(_integration) = { found: 0, fresh: 0, removed: 0, keys: 0 }
      def poll(_device) = nil # quem manda é o gateway

      def panel? = true
      def panel_locals(integration, _params)
        s = integration.settings
        { rows: [ [ text(:path), "/mensageiros/#{integration.id}" ], [ text(:passkey), s["passkey"].present? ? "#{s['passkey'][0, 6]}…" : text(:waiting) ],
                  [ text(:last), s["last_at"] ] ], stats: [ [ title, text(:setup) ] ] }
      end

      # → [{campo, valor, opções}] do envio, já no sistema métrico.
      def readings(data)
        list = data.filter_map do |k, v|
          next if v.to_s.strip.empty?

          if (spec = FIELDS[k])
            f, conv, opts = spec
            [ f, conv ? conv.call(v) : v.to_f, opts, nil ]
          elsif (m = CHANNELS.find { |re, *| k.match?(re) })
            [ "#{m[1]}:#{k[m[0], 1]}", m[2] ? m[2].call(v) : v.to_f, m[3], k[m[0], 1] ]
          end
        end
        list.map { |f, v, opts, n| { "field" => f, "value" => v, "opts" => opts, "n" => n } }
      end

      def webhook(integration, request)
        data = request.request_parameters.presence || request.query_parameters
        passkey = data["PASSKEY"].to_s
        return [ 400, "PASSKEY?" ] if passkey.blank?

        known = integration.settings["passkey"]
        return [ 403, text(:wrong_gateway) ] if known.present? && !ActiveSupport::SecurityUtils.secure_compare(known, passkey)

        integration.update!(settings: integration.settings.merge("passkey" => passkey, "last_at" => Time.current.iso8601))
        device = gateway(integration, passkey, data["stationtype"])
        have = device.points.index_by { |p| p.address["field"] }
        readings(data).each do |r|
          p = have[r["field"]] || device.points.create!(point_attrs(device, r))
          p.report!(r["value"])
        end
        device.update_columns(status: "online", last_seen_at: Time.current)
        integration.ok!
        [ 200, "OK" ]
      end

      def gateway(integration, passkey, model)
        integration.site.devices.find_or_create_by!(driver: driver, external_id: "ecowitt:#{passkey}") do |d|
          d.assign_attributes(name: "Ecowitt #{model}".strip, integration: integration, manufacturer: "Ecowitt", model: model, poll_s: 0)
        end
      end

      def point_attrs(device, r)
        base = r["field"].split(":").first
        name = r["n"] ? text("points.#{base}", n: r["n"]) : text("points.#{base}")
        point(r["field"], name: name, state_class: "measurement", **r["opts"])
          .merge("site" => device.site, "key" => Integrations.unique_key(device.site, device, name))
      end
    end
  end
end
