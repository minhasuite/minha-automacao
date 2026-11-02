module Integrations
  # Zigbee pelo zigbee2mqtt: mesmo broker (driver mqtt) e descoberta do Mqtt::Z2m.
  class Zigbee2mqttPlugin < MqttPlugin
    describe key: "zigbee2mqtt", title: "Zigbee2MQTT", icon: "switch-horizontal", driver: "mqtt",
             description: "Aparelhos Zigbee pelo coordenador USB. Fica desligado até o coordenador chegar; depois os aparelhos aparecem sozinhos."
    texts en: { title: "Zigbee2MQTT", description: "Zigbee devices through the USB coordinator. It stays off until the coordinator arrives; then devices show up on their own." },
          es: { title: "Zigbee2MQTT", description: "Aparatos Zigbee mediante el coordinador USB. Queda apagado hasta que llegue el coordinador; después los aparatos aparecen solos." }
  end
end
