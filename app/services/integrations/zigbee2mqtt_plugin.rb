module Integrations
  # Zigbee pelo zigbee2mqtt: mesmo broker (driver mqtt) e descoberta do Mqtt::Z2m.
  class Zigbee2mqttPlugin < MqttPlugin
    describe key: "zigbee2mqtt", title: "Zigbee2MQTT", icon: "switch-horizontal", driver: "mqtt",
             description: "Aparelhos Zigbee pelo coordenador USB. Fica desligado até o coordenador chegar; depois os aparelhos aparecem sozinhos."
  end
end
