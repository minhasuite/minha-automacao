module Integrations
  # Zigbee pelo zigbee2mqtt: mesmo broker (driver mqtt) e descoberta do Mqtt::Z2m.
  class Zigbee2mqttPlugin < MqttPlugin
    describe key: "zigbee2mqtt", title: "Zigbee2MQTT", icon: "switch-horizontal", driver: "mqtt",
             description: "Aparelhos Zigbee pelo coordenador USB. Fica desligado até o coordenador chegar; depois os aparelhos aparecem sozinhos."
    texts en: { title: "Zigbee2MQTT", description: "Zigbee devices through the USB coordinator. It stays off until the coordinator arrives; then devices show up on their own." },
          es: { title: "Zigbee2MQTT", description: "Aparatos Zigbee mediante el coordinador USB. Queda apagado hasta que llegue el coordinador; después los aparatos aparecen solos." }
    # ondaA2 A19: coordenadores USB comuns (Sonoff ZBDongle-P/E, ConBee II, CC2652, SkyConnect).
    usb({ vid: "10C4", pid: "EA60", description: "*sonoff*" }, { vid: "1A86", pid: "55D4", description: "*sonoff*" }, { vid: "1CF1", pid: "0030" },
        { vid: "0451", pid: "BEF3" }, { vid: "10C4", pid: "EA60", description: "*skyconnect*" })

    # Assistente de pareamento, renome que chega ao z2m e mapa da rede.
    def self.pairing_bridge = Mqtt::Z2m::Bridge
  end
end
