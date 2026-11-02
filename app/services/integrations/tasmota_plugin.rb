module Integrations
  # Tasmota pelo broker do servidor (Pacote 1): mesma conexão (driver mqtt) e
  # descoberta nativa do Tasmota no Mqtt::Tasmota.
  class TasmotaPlugin < MqttPlugin
    describe key: "tasmota", title: "Tasmota", icon: "switch-horizontal", driver: "mqtt",
             description: "Tomadas, relés e sensores com Tasmota no broker MQTT do servidor. Com a descoberta ligada no aparelho, aparecem sozinhos."
    texts en: { title: "Tasmota", description: "Plugs, relays and sensors running Tasmota on the server's MQTT broker. With discovery on in the device, they show up on their own." },
          es: { title: "Tasmota", description: "Enchufes, relés y sensores con Tasmota en el broker MQTT del servidor. Con el descubrimiento activado en el aparato, aparecen solos." }
  end
end
