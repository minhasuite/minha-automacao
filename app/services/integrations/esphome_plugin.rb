module Integrations
  # ESPHome (Pacote 1): placa ESP na rede pela API nativa (TCP 6053), com a
  # chave de criptografia do YAML (`api: encryption: key`) e a senha antiga,
  # se houver. Achado por mDNS `_esphomelib._tcp` (só lista). As entidades
  # viram pontos pelo `config/device_maps/esphome.yml`; tempo real pelo
  # `Esphome::Listener`.
  class EsphomePlugin < LanPlugin
    describe key: "esphome", title: "ESPHome", icon: "chip",
             description: "Placas ESP32/ESP8266 com ESPHome na rede de casa: sensores, relés, luzes, cortinas e botões, em tempo real. Ache na rede ou informe o IP e a chave da API."
    texts en: { title: "ESPHome", description: "ESP32/ESP8266 boards running ESPHome on your home network: sensors, relays, lights, covers and buttons, in real time. Find it on the network or enter the IP and API key." },
          es: { title: "ESPHome", description: "Placas ESP32/ESP8266 con ESPHome en la red de casa: sensores, relés, luces, cortinas y botones, en tiempo real. Encuéntrala en la red o ingresa la IP y la clave de la API." }
    port 6053
    secrets :encryption_key, :password
    mdns "_esphomelib._tcp"

    def self.probe(integration)
      s = integration.secrets
      host = host_of(integration)
      info, entities, = Esphome.read(host: host, port: port_of(integration), key: s["encryption_key"], password: s["password"])
      { "id" => info["mac"].presence || info["name"], "kind" => "esphome", "name" => info["friendly_name"].presence || info["name"] || host,
        "manufacturer" => info["manufacturer"].presence || "ESPHome", "model" => info["model"], "category" => "ESPHome #{info['version']}".strip,
        "address" => { "host" => host, "port" => port_of(integration) }, "poll_s" => 1800, "points" => Esphome.points(entities) }
    rescue Esphome::Error, *NET_ERRORS => e
      raise e.is_a?(AuthError) ? Integrations.auth(Integrations::Error.new(e.message)) : Integrations::Error.new(e.message)
    end

    # Estado logo depois da adoção (o ouvinte assume em até 1 min).
    def self.refresh(integration)
      integration.devices.where(driver: driver, removed_at: nil, disabled: false).find_each do |d|
        Drivers::Esphome.poll(d)
      rescue Esphome::Error, *NET_ERRORS => e
        Rails.logger.warn("[esphome] estado de #{d.name}: #{e.message}")
      end
    end
  end
end
