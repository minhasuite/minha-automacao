require "rails_helper"

RSpec.describe "Driver mqtt e zigbee2mqtt" do
  let(:tenant) { create(:tenant) }
  let(:site) { within(tenant) { create(:site) } }
  let(:device) { within(tenant) { create(:device, site: site, driver: "mqtt", name: "Sensor") } }

  around { |ex| with_env("MQTT_URL" => "mqtt://u:p@broker:1883") { ex.run } }

  def with_env(vars)
    old = vars.keys.index_with { |k| ENV.fetch(k, nil) }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  def point(**attrs) = within(tenant) { create(:point, device: device, **attrs) }

  describe Drivers::Mqtt do
    it "payload: JSON no caminho com on/off configuráveis; número volta ao bruto" do
      relay = point(address: { "topic" => "z/rele", "json_path" => "state_l1", "payload_on" => "ON", "payload_off" => "OFF" })
      expect(described_class.payload(relay, true)).to eq('{"state_l1":"ON"}')
      dimmer = point(capability: "dimmer", scale: "0.5", address: { "topic" => "z/luz", "json_path" => "a.b" })
      expect(described_class.payload(dimmer, 50)).to eq('{"a":{"b":100}}')
      plain = point(address: { "topic" => "casa/rele" })
      expect(described_class.payload(plain, false)).to eq("false")
    end

    it "value_for: lê o campo, converte on/off e calibra; ignora o que não é do ponto" do
      relay = point(address: { "topic" => "z/rele", "json_path" => "state", "payload_on" => "ON", "payload_off" => "OFF" })
      expect(described_class.value_for(relay, '{"state":"ON"}')).to be true
      expect(described_class.value_for(relay, '{"state":"OFF"}')).to be false
      expect(described_class.value_for(relay, '{"battery":90}')).to be_nil
      expect(described_class.value_for(relay, "não é json")).to be_nil
      temp = point(capability: "measure", scale: "0.1", address: { "topic" => "t", "json_path" => "sensor.raw" })
      expect(described_class.value_for(temp, '{"sensor":{"raw":253}}')).to eq(25.3)
      text = point(capability: "text", address: { "topic" => "t" })
      expect(described_class.value_for(text, "olá")).to eq("olá")
      num = point(capability: "measure", address: { "topic" => "t" })
      expect(described_class.value_for(num, "21.5")).to eq(21.5)
    end

    it "comando publica no tópico de comando; sem tópico de estado o ponto muda na hora" do
      client = instance_double(MQTT::Client)
      allow(MQTT::Client).to receive(:connect).and_yield(client)
      allow(client).to receive(:publish)
      relay = point(address: { "topic" => "z/rele", "json_path" => "state", "payload_on" => "ON", "payload_off" => "OFF" })
      described_class.new.execute(relay, "on", nil)
      expect(client).to have_received(:publish).with("z/rele/set", '{"state":"ON"}')
      expect(relay.reload.value).to be_nil # espera o eco do estado

      only_cmd = point(address: { "command_topic" => "casa/sirene/cmd" })
      described_class.new.execute(only_cmd, "on", nil)
      expect(client).to have_received(:publish).with("casa/sirene/cmd", "true")
      expect(only_cmd.reload.value).to be true
    end

    it "sem tópico, sem broker ou broker fora do ar: falha com o motivo" do
      expect { described_class.new.execute(point(address: {}), "on", nil) }.to raise_error(Drivers::Mqtt::Error, /sem tópico/i)
      relay = point(address: { "topic" => "z/r" })
      allow(MQTT::Client).to receive(:connect).and_raise(Errno::ECONNREFUSED)
      expect { described_class.new.execute(relay, "on", nil) }.to raise_error(Drivers::Mqtt::Error, /Sem conexão com o broker/)
      with_env("MQTT_URL" => nil) do
        expect { described_class.new.execute(relay, "on", nil) }.to raise_error(Drivers::Mqtt::Error, /não configurado/)
      end
    end

    it "comando pela fila (Points::Command) chega ao driver" do
      client = instance_double(MQTT::Client, publish: nil)
      allow(MQTT::Client).to receive(:connect).and_yield(client)
      relay = point(address: { "command_topic" => "c" })
      command = within(tenant) { Points::Command.call(relay, "on", source: "web") }
      perform_enqueued_jobs
      expect(command.reload.status).to eq("confirmed")
    end
  end

  describe Mqtt::Listener do
    it "mensagem no tópico vira valor do ponto e o aparelho fica online" do
      relay = point(address: { "topic" => "z/rele", "json_path" => "state", "payload_on" => "ON", "payload_off" => "OFF" })
      other = point(capability: "measure", address: { "topic" => "z/rele", "json_path" => "power" })
      described_class.handle("z/rele", '{"state":"ON","power":12}')
      expect(relay.reload.value).to be true
      expect(other.reload.value).to eq(12)
      expect(device.reload.status).to eq("online")
      expect(described_class.topics).to contain_exactly("z/rele", "zigbee2mqtt/bridge/devices") # único local: descoberta ligada
    end

    it "queda do broker deixa os pontos indisponíveis" do
      relay = point(address: { "topic" => "z/rele" }, value: true)
      allow(MQTT::Client).to receive(:connect).and_raise(Errno::ECONNREFUSED)
      expect(described_class.session).to be false
      expect(relay.reload.quality).to eq("unavailable")
    end

    it "sessão: assina os tópicos, entrega as mensagens e reconecta quando cai" do
      relay = point(address: { "topic" => "z/rele", "json_path" => "state", "payload_on" => "ON", "payload_off" => "OFF" })
      client = instance_double(MQTT::Client, connected?: true)
      allow(MQTT::Client).to receive(:connect).and_yield(client)
      allow(client).to receive(:subscribe).and_return(true)
      allow(client).to receive(:queue_empty?).and_return(false)
      calls = 0
      allow(client).to receive(:get) do
        (calls += 1) == 1 ? [ "z/rele", '{"state":"ON"}' ] : raise(MQTT::ProtocolException, "caiu")
      end
      expect(described_class.session).to be true
      expect(client).to have_received(:subscribe).with("z/rele" => 0)
      expect(relay.reload).to have_attributes(value: true, quality: "unavailable")
    end

    it "não liga sem MQTT_URL" do
      with_env("MQTT_URL" => nil) { expect(described_class.start).to be_nil }
    end
  end

  describe Mqtt::Z2m do
    let(:payload) { file_fixture("z2m_bridge_devices.json").read }

    it "descobre aparelhos e pontos a partir do bridge/devices (formato real do z2m)" do
      result = described_class.discover!(site, payload)
      expect(result).to eq(devices: 5, points: 13)
      within(tenant) do
        expect(site.devices.pluck(:name)).to contain_exactly("sala_temperatura", "porta_cozinha", "movimento_corredor", "interruptor_varanda", "luz_quarto")
        temp = Point.find_by!(key: "sala_temperatura.temperature")
        expect(temp).to have_attributes(capability: "measure", unit: "°C", name: "Temperatura", writable: false, device_class: "temperature")
        expect(temp.address).to eq("topic" => "zigbee2mqtt/sala_temperatura", "json_path" => "temperature")
        expect(Point.where(key: "sala_temperatura.linkquality")).to be_empty

        door = Point.find_by!(key: "porta_cozinha.contact")
        expect(door.capability).to eq("contact")
        expect(Drivers::Mqtt.value_for(door, '{"contact":false}')).to be true # aberta
        expect(Drivers::Mqtt.value_for(door, '{"contact":true}')).to be false

        expect(Point.find_by!(key: "movimento_corredor.occupancy").capability).to eq("motion")
        l1 = Point.find_by!(key: "interruptor_varanda.state_l1")
        expect(l1).to have_attributes(capability: "onoff", writable: true, name: "Liga/desliga l1")
        expect(Drivers::Mqtt.payload(l1, true)).to eq('{"state_l1":"ON"}')
        expect(Point.find_by!(key: "interruptor_varanda.power_on_behavior")).to have_attributes(capability: "enum", options: %w[off on previous])
        expect(Point.find_by!(key: "interruptor_varanda.action").capability).to eq("event")

        bright = Point.find_by!(key: "luz_quarto.brightness")
        expect(bright.capability).to eq("dimmer")
        expect(Drivers::Mqtt.value_for(bright, '{"brightness":254}')).to eq(100)
        expect(Drivers::Mqtt.payload(bright, 50)).to eq('{"brightness":127}')
      end
    end

    it "é idempotente e acompanha a troca de nome no z2m" do
      described_class.discover!(site, payload)
      renamed = JSON.parse(payload).each { |d| d["friendly_name"] = "sala_termometro" if d["friendly_name"] == "sala_temperatura" }.to_json
      expect(described_class.discover!(site, renamed)).to eq(devices: 0, points: 0)
      within(tenant) do
        expect(Point.find_by!(key: "sala_temperatura.temperature").address["topic"]).to eq("zigbee2mqtt/sala_termometro")
        expect(Device.find_by!(external_id: "0xa4c138f1d2b4e5f1").name).to eq("sala_termometro")
      end
    end

    it "o ouvinte assina o bridge/devices e descobre no único local do servidor" do
      site
      expect(ActsAsTenant.without_tenant { described_class.site }).to eq(site)
      expect(Mqtt::Listener.topics).to include("zigbee2mqtt/bridge/devices")
      Mqtt::Listener.handle("zigbee2mqtt/bridge/devices", payload)
      expect(within(tenant) { site.devices.count }).to eq(5)
    end

    it "com mais de um local, só com Z2M_SITE_ID" do
      site
      within(tenant) { create(:site) }
      expect(ActsAsTenant.without_tenant { described_class.site }).to be_nil
      with_env("Z2M_SITE_ID" => site.id) { expect(ActsAsTenant.without_tenant { described_class.site }).to eq(site) }
    end
  end
end
