module Integrations
  # Broker MQTT do servidor: os aparelhos entram sozinhos (Mqtt::Z2m ou
  # cadastro manual); a varredura só os liga ao card.
  class MqttPlugin < Plugin
    describe key: "mqtt", title: "MQTT", icon: "switch-horizontal",
             description: "Sensores e aparelhos que conversam por MQTT com o servidor da casa. Aparecem sozinhos quando mandam o primeiro dado."

    def self.setup(site, _form)
      i = site.integrations.find_or_create_by!(driver: driver) { |n| n.assign_attributes(name: title, poll_s: Integration::SYNC_S) }
      i.update!(settings: i.settings.merge("account" => ENV["MQTT_URL"].present? ? "Broker do servidor" : "Sem broker neste servidor"))
      Integrations.sync!(i)
      outcome(:index, notice: "#{title} adicionada. Os aparelhos aparecem sozinhos quando publicarem.")
    end

    def self.reconfigurable? = false

    def self.inventory(integration)
      integration.site.devices.where(driver: "mqtt").map do |d|
        { "id" => d.external_id, "kind" => "mqtt", "name" => d.name, "manufacturer" => d.manufacturer, "model" => d.model, "points" => [] }
      end
    end
  end
end
