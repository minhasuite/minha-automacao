module Integrations
  # Tasmota pelo broker do servidor (Pacote 1): mesma conexão (driver mqtt) e
  # descoberta nativa do Tasmota no Mqtt::Tasmota.
  class TasmotaPlugin < MqttPlugin
    describe key: "tasmota", title: "Tasmota", icon: "switch-horizontal", driver: "mqtt",
             description: "Tomadas, relés e sensores com Tasmota no broker MQTT do servidor. Com a descoberta ligada no aparelho, aparecem sozinhos."
  end
end
