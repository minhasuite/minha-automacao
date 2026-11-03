module Integrations
  # Netatmo (catalogo): estação meteorológica (módulos internos e externos,
  # chuva e vento) e termostatos/válvulas por cômodo, pela API Netatmo
  # (OAuth do app do dono em dev.netatmo.com). Cômodo com termostato aceita a
  # temperatura alvo (modo manual por 3 h, como o app).
  class NetatmoPlugin < OauthPlugin
    describe key: "netatmo", title: "Netatmo", icon: "thermometer",
             description: "Estação meteorológica Netatmo (temperatura, umidade, CO₂, ruído, pressão, chuva e vento) e termostatos e válvulas por cômodo, com a temperatura alvo."
    texts "pt-BR" => { points: { setpoint: "Temperatura alvo" }, note: "Crie o app em dev.netatmo.com → My apps e informe o Client ID e o secret dele." },
          en: { title: "Netatmo", description: "Netatmo weather station (temperature, humidity, CO₂, noise, pressure, rain and wind) and thermostats and valves per room, with the target temperature.",
                points: { setpoint: "Target temperature" }, note: "Create the app at dev.netatmo.com → My apps and enter its Client ID and secret." },
          es: { title: "Netatmo", description: "Estación meteorológica Netatmo (temperatura, humedad, CO₂, ruido, presión, lluvia y viento) y termostatos y válvulas por habitación, con la temperatura objetivo.",
                points: { setpoint: "Temperatura objetivo" }, note: "Crea la app en dev.netatmo.com → My apps e indica su Client ID y secret." }
    oauth authorize: "https://api.netatmo.com/oauth2/authorize", token: "https://api.netatmo.com/oauth2/token",
          scope: "read_station read_thermostat write_thermostat read_camera access_camera read_presence access_presence read_doorbell access_doorbell"
    API = "https://api.netatmo.com/api".freeze

    # Medida do dashboard_data → [campo, opções].
    MEASURES = {
      "Temperature" => [ "temperature", { unit: "°C", device_class: "temperature", state_class: "measurement" } ],
      "Humidity" => [ "humidity", { unit: "%", device_class: "humidity", state_class: "measurement" } ],
      "CO2" => [ "co2", { unit: "ppm", device_class: "carbon_dioxide", state_class: "measurement" } ],
      "Noise" => [ "noise", { unit: "dB", state_class: "measurement" } ],
      "Pressure" => [ "pressure", { unit: "hPa", device_class: "pressure", state_class: "measurement" } ],
      "Rain" => [ "rain", { unit: "mm", state_class: "measurement" } ],
      "WindStrength" => [ "wind_speed", { unit: "km/h", state_class: "measurement" } ]
    }.freeze

    class << self
      # Estação e módulos: {id, name, data, battery}.
      def stations(integration)
        Array(api(integration, :get, "#{API}/getstationsdata").dig("body", "devices")).flat_map do |d|
          [ { "id" => d["_id"], "name" => d["module_name"].presence || d["station_name"], "data" => d["dashboard_data"].to_h, "model" => d["type"] } ] +
            Array(d["modules"]).map { |m| { "id" => m["_id"], "name" => m["module_name"], "data" => m["dashboard_data"].to_h, "battery" => m["battery_percent"], "model" => m["type"] } }
        end
      end

      # Cômodos com aquecimento: {home, id, name, temperature, setpoint}.
      def rooms(integration)
        Array(api(integration, :get, "#{API}/homesdata").dig("body", "homes")).flat_map do |h|
          names = Array(h["rooms"]).to_h { |r| [ r["id"], r["name"] ] }
          status = api(integration, :get, "#{API}/homestatus?home_id=#{CGI.escape(h['id'].to_s)}").dig("body", "home", "rooms")
          Array(status).filter_map do |r|
            next unless r.key?("therm_setpoint_temperature")

            { "home" => h["id"], "id" => r["id"], "name" => names[r["id"]] || r["id"], "temperature" => r["therm_measured_temperature"], "setpoint" => r["therm_setpoint_temperature"] }
          end
        end
      end

      def entries(integration)
        weather = stations(integration).map do |s|
          pts = MEASURES.filter_map { |k, (f, o)| point(f, **o) if s["data"].key?(k) }
          pts << point("battery", unit: "%", device_class: "battery", state_class: "measurement") if s["battery"]
          entry(id: "netatmo:#{s['id']}", name: s["name"], model: s["model"], address: { "module" => s["id"] }, poll_s: 600, points: pts)
        end
        heat = rooms(integration).map do |r|
          entry(id: "netatmo:room:#{r['id']}", name: r["name"], model: "Netatmo Energy", room: r["name"], address: { "home" => r["home"], "room" => r["id"] }, poll_s: 300,
                points: [ point("temperature", unit: "°C", device_class: "temperature", state_class: "measurement"),
                          point("setpoint", "setpoint", unit: "°C", min: 7, max: 30, step: 0.5) ])
        end
        weather + heat + cameras(integration).map do |c|
          entry(id: "netatmo:cam:#{c['id']}", name: c["name"], model: c["type"], address: { "home" => c["home"], "camera" => c["id"] }, poll_s: 300,
                points: [ point("video", "stream", name: I18n.t("resto.cameras.video"), history: "none", writable: false, address: { "on_demand" => true }), point("monitoring", "text", name: I18n.t("resto.cameras.monitoring"), writable: false) ])
        end
      end

      # resto: câmeras (NACamera, NOC, NDB) → [{id, name, type, home, vpn_url, monitoring}].
      CAMERAS = %w[NACamera NOC NDB NSD].freeze

      def cameras(integration)
        Array(api(integration, :get, "#{API}/homesdata").dig("body", "homes")).flat_map do |h|
          mods = Array(h["modules"]).select { |m| CAMERAS.include?(m["type"]) }
          next [] if mods.empty?

          status = Array(api(integration, :get, "#{API}/homestatus?home_id=#{CGI.escape(h['id'].to_s)}").dig("body", "home", "modules")).index_by { |m| m["id"] }
          mods.map { |m| { "id" => m["id"], "name" => m["name"], "type" => m["type"], "home" => h["id"] }.merge(status[m["id"]].to_h.slice("vpn_url", "monitoring", "is_local")) }
        end
      end

      def stream_url(point)
        c = cameras(point.device.integration).find { |x| x["id"] == point.device.address["camera"] } or return nil
        "ffmpeg:#{c['vpn_url']}/live/files/high/index.m3u8#video=copy" if c["vpn_url"].present?
      end

      def read(device)
        i = device.integration
        if (cam = device.address["camera"])
          return { "monitoring" => cameras(i).find { |x| x["id"] == cam }&.dig("monitoring") }
        end
        if (room = device.address["room"])
          r = rooms(i).find { |x| x["id"] == room }.to_h
          return { "temperature" => r["temperature"], "setpoint" => r["setpoint"] }
        end
        s = stations(i).find { |x| x["id"] == device.address["module"] }.to_h
        MEASURES.to_h { |k, (f, _)| [ f, s["data"][k] ] }.merge("battery" => s["battery"])
      end

      def write(point, value)
        a = point.device.address
        api(point.device.integration, :post, "#{API}/setroomthermpoint", { home_id: a["home"], room_id: a["room"], mode: "manual", temp: value.to_f,
                                                                           endtime: 3.hours.from_now.to_i })
      end
    end
  end
end
