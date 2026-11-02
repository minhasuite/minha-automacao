module Drivers
  # LG ThinQ (integ2): ACs da conta pela API oficial ThinQ Connect, com o
  # token de acesso pessoal (PAT, connect-pat.lgthinq.com). Região Américas
  # (`api-aic`); o país vai em `x-country`. Lê o estado a cada 2 min e o
  # comando grava o pedido (a nuvem demora a refletir). Endereço {device_id}.
  class LgThinq < Climate
    URL = "https://api-aic.lgthinq.com".freeze
    API_KEY = "v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3".freeze # chave pública do app ThinQ Connect (igual para todos)
    TYPE = "DEVICE_AIR_CONDITIONER".freeze

    def self.vendor = "lg_thinq"
    def self.reread? = false

    def self.headers(integration)
      s = integration.settings
      { "Authorization" => "Bearer #{integration.secrets['token']}", "x-country" => s["country"].presence || "BR",
        "x-client-id" => s["client_id"].to_s, "x-message-id" => SecureRandom.urlsafe_base64(16)[0, 22],
        "x-api-key" => API_KEY, "x-service-phase" => "OP" }
    end

    def self.api(integration, method, path, body = nil)
      LanHttp.call(method, "#{URL}#{path}", body: body, headers: headers(integration), timeout: 15).fetch("response") do
        raise Integrations::Error, "A LG respondeu sem dados."
      end
    end

    def self.inventory(integration)
      Array(api(integration, :get, "/devices")).filter_map do |d|
        info = d["deviceInfo"].to_h
        next unless info["deviceType"] == TYPE

        climate_entry(id: "lg_thinq:#{d['deviceId']}", name: info["alias"].presence || "Ar LG", manufacturer: "LG", model: info["modelName"],
                      address: { "device_id" => d["deviceId"] }, poll_s: 120)
      end
    end

    def self.read(device)
      s = api(device.integration, :get, "/devices/#{device.address['device_id']}/state")
      t = s["temperature"].to_h
      { "power" => s.dig("operation", "airConOperationMode") == "POWER_ON", "mode" => label("mode", s.dig("airConJobMode", "currentJobMode")),
        "target" => t["targetTemperature"]&.to_f, "fan" => label("fan", s.dig("airFlow", "windStrength")), "current" => t["currentTemperature"]&.to_f }
    end

    def self.write(device, field, value)
      body = case field
      when "power" then { operation: { airConOperationMode: value ? "POWER_ON" : "POWER_OFF" } }
      when "target" then { temperature: { targetTemperature: value.to_f, unit: "C" } }
      when "mode" then { airConJobMode: { currentJobMode: code("mode", value) } }
      when "fan" then { airFlow: { windStrength: code("fan", value) } }
      end
      api(device.integration, :post, "/devices/#{device.address['device_id']}/control", body)
    end
  end
end
