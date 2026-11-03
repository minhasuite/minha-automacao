module Integrations
  # Broker MQTT do servidor: os aparelhos entram sozinhos (Mqtt::Z2m,
  # Mqtt::Tasmota, Mqtt::HaDiscovery ou cadastro manual); a varredura só os liga ao card.
  class MqttPlugin < Plugin
    describe key: "mqtt", title: "MQTT", icon: "switch-horizontal",
             description: "Sensores e aparelhos que conversam por MQTT com o servidor da casa. Quem segue a descoberta do Home Assistant (homeassistant/…: OpenMQTTGateway, ESPHome, Shelly, Theengs, rtl_433…) aparece sozinho."
    texts "pt-BR" => { added: "%{name} adicionada. Os aparelhos aparecem sozinhos quando publicarem." },
          en: { title: "MQTT", description: "Sensors and devices that talk MQTT with the home server. Anything that follows Home Assistant discovery (homeassistant/…: OpenMQTTGateway, ESPHome, Shelly, Theengs, rtl_433…) shows up on its own.", added: "%{name} added. Devices show up on their own when they publish." },
          es: { title: "MQTT", description: "Sensores y aparatos que se comunican por MQTT con el servidor de casa. Lo que sigue el descubrimiento de Home Assistant (homeassistant/…: OpenMQTTGateway, ESPHome, Shelly, Theengs, rtl_433…) aparece solo.", added: "%{name} agregada. Los aparatos aparecen solos cuando publiquen." }

    def self.setup(site, _form)
      i = site.integrations.find_or_create_by!(driver: driver) { |n| n.assign_attributes(name: title, poll_s: Integration::SYNC_S) }
      i.update!(settings: i.settings.merge("account" => ENV["MQTT_URL"].present? ? "Broker do servidor" : "Sem broker neste servidor"))
      Integrations.sync!(i)
      outcome(:index, notice: text(:added, name: title))
    end

    def self.reconfigurable? = false

    def self.inventory(integration)
      integration.site.devices.where(driver: "mqtt").map do |d|
        { "id" => d.external_id, "kind" => "mqtt", "name" => d.name, "manufacturer" => d.manufacturer, "model" => d.model, "points" => [] }
      end
    end
  end
end
