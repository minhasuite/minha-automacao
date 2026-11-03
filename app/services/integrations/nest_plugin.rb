module Integrations
  # Google Nest (catalogo): termostatos Nest pela Smart Device Management API
  # (Device Access do Google: projeto do dono + cliente OAuth do Google
  # Cloud). Temperatura, umidade, modo, temperatura alvo (aquecer/resfriar) e
  # câmeras e campainhas ficam de fora (o vídeo do SDM pede WebRTC e Pub/Sub).
  class NestPlugin < OauthPlugin
    describe key: "nest", title: "Google Nest", icon: "thermometer",
             description: "Termostatos Google Nest: temperatura e umidade do ambiente, modo (aquecer, resfriar, desligado) e a temperatura alvo, pela Device Access do Google."
    texts "pt-BR" => { fields: { project_id: "Id do projeto do Device Access" }, points: { mode: "Modo", heat: "Aquecer até", cool: "Resfriar até" },
                       note: "Precisa do Device Access do Google (taxa única de US$ 5 cobrada pelo Google) e de um cliente OAuth do Google Cloud. Passo a passo em docs/catalogo.md." },
          en: { title: "Google Nest", description: "Google Nest thermostats: room temperature and humidity, mode (heat, cool, off) and the target temperature, through Google's Device Access.",
                fields: { project_id: "Device Access project ID" }, points: { mode: "Mode", heat: "Heat to", cool: "Cool to" },
                note: "Needs Google's Device Access (one-time US$ 5 fee charged by Google) and a Google Cloud OAuth client. Step by step in docs/catalogo.md." },
          es: { title: "Google Nest", description: "Termostatos Google Nest: temperatura y humedad del ambiente, modo (calentar, enfriar, apagado) y la temperatura objetivo, mediante Device Access de Google.",
                fields: { project_id: "Id del proyecto de Device Access" }, points: { mode: "Modo", heat: "Calentar hasta", cool: "Enfriar hasta" },
                note: "Necesita Device Access de Google (tarifa única de US$ 5 cobrada por Google) y un cliente OAuth de Google Cloud. Paso a paso en docs/catalogo.md." }
    field :project_id, required: true
    oauth authorize: "https://nestservices.google.com/partnerconnections", token: "https://oauth2.googleapis.com/token",
          scope: "https://www.googleapis.com/auth/sdm.service", params: { access_type: "offline", prompt: "consent" }
    API = "https://smartdevicemanagement.googleapis.com/v1".freeze
    T = "sdm.devices.traits.".freeze
    MODES = %w[HEAT COOL HEATCOOL OFF].freeze

    class << self
      def authorize_url(integration) = "#{oauth_config[:authorize]}/#{CGI.escape(conf(integration, :project_id).to_s)}/auth"
      def project(integration) = "#{API}/enterprises/#{CGI.escape(conf(integration, :project_id).to_s)}"

      def devices(integration) = Array(api(integration, :get, "#{project(integration)}/devices")["devices"])

      def entries(integration)
        devices(integration).filter_map do |d|
          next unless d["type"].to_s.end_with?("THERMOSTAT")

          tr = d["traits"].to_h
          name = tr.dig("#{T}Info", "customName").presence || Array(d["parentRelations"]).first&.dig("displayName") || "Nest"
          modes = Array(tr.dig("#{T}ThermostatMode", "availableModes")).presence || MODES
          entry(id: "nest:#{d['name'].to_s.split('/').last}", name: name, manufacturer: "Google", model: "Nest", room: Array(d["parentRelations"]).first&.dig("displayName"),
                address: { "name" => d["name"] }, poll_s: 300,
                points: [ point("temperature", unit: "°C", device_class: "temperature", state_class: "measurement"),
                          point("humidity", unit: "%", device_class: "humidity", state_class: "measurement"),
                          point("mode", "enum", options: modes), point("heat", "setpoint", unit: "°C", min: 9, max: 32, step: 0.5),
                          point("cool", "setpoint", unit: "°C", min: 9, max: 32, step: 0.5) ])
        end
      end

      def read(device)
        tr = api(device.integration, :get, "#{API}/#{device.address['name']}")["traits"].to_h
        sp = tr["#{T}ThermostatTemperatureSetpoint"].to_h
        { "temperature" => tr.dig("#{T}Temperature", "ambientTemperatureCelsius")&.round(1), "humidity" => tr.dig("#{T}Humidity", "ambientHumidityPercent"),
          "mode" => tr.dig("#{T}ThermostatMode", "mode"), "heat" => sp["heatCelsius"]&.round(1), "cool" => sp["coolCelsius"]&.round(1) }
      end

      def write(point, value)
        f = point.address["field"]
        cmd = if f == "mode" then { command: "sdm.devices.commands.ThermostatMode.SetMode", params: { mode: value } }
        else
                cur = point.device.points.to_h { |p| [ p.address["field"], p.value ] }
                if cur["mode"] == "HEATCOOL"
                  { command: "sdm.devices.commands.ThermostatTemperatureSetpoint.SetRange",
                    params: { heatCelsius: (f == "heat" ? value : cur["heat"]).to_f, coolCelsius: (f == "cool" ? value : cur["cool"]).to_f } }
                else
                  { command: "sdm.devices.commands.ThermostatTemperatureSetpoint.Set#{f.capitalize}", params: { "#{f}Celsius": value.to_f } }
                end
        end
        api(point.device.integration, :post, "#{API}/#{point.device.address['name']}:executeCommand", cmd)
      end
    end
  end
end
