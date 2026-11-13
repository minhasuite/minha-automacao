# Broker MQTT falso para o zigbee2mqtt (docs/integracoes.md, "Zigbee"): o que
# o servidor publicaria fica guardado aqui (nada sai para a rede) e as
# mensagens da ponte entram pelo ouvinte de verdade (`Mqtt::Listener.handle`).
#
#   broker = FakeMqttBroker.install(self)          # num before/it
#   broker.deliver("zigbee2mqtt/bridge/event", { type: "device_joined", data: {...} })
#   broker.last("bridge/request/permit_join")       # → Hash publicado
class FakeMqttBroker
  attr_reader :published

  def self.install(example, url: "mqtt://broker-falso:1883")
    new.tap do |b|
      example.allow(Drivers::Mqtt).to example.receive(:url).and_return(url)
      example.allow(Mqtt::Listener).to example.receive(:publish) { |topic, payload, **| b.published << [ topic, payload ] }
    end
  end

  def initialize = @published = []

  def deliver(topic, payload) = Mqtt::Listener.handle(topic, payload.is_a?(String) ? payload : payload.to_json)

  def topics = published.map(&:first)

  def last(path, base: "zigbee2mqtt")
    found = published.reverse.find { |t, _| t == "#{base}/#{path}" }
    found && JSON.parse(found.last)
  end
end
