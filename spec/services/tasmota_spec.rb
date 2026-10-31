require "rails_helper"

# Pacote 1: descoberta nativa do Tasmota pelo broker e o registro de
# descobridores do Mqtt::Listener. Nada sai para a rede.
RSpec.describe "Tasmota pelo MQTT" do
  let(:tenant) { create(:tenant) }
  let!(:site) { ActsAsTenant.with_tenant(tenant) { create(:site) } }

  # Mensagens retidas como o Tasmota 13 publica.
  let(:config) do
    { "ip" => "192.168.0.60", "dn" => "Tomada Sala", "fn" => [ "Abajur", nil, nil, nil, nil, nil, nil, nil ], "hn" => "tasmota-ABCDEF-1234",
      "mac" => "AABBCCABCDEF", "md" => "Sonoff Pow R2", "ty" => 0, "if" => 0, "ofln" => "Offline", "onln" => "Online",
      "state" => %w[OFF ON TOGGLE HOLD], "sw" => "13.2.0", "t" => "tasmota_ABCDEF", "ft" => "%prefix%/%topic%/", "tp" => %w[cmnd stat tele],
      "rl" => [ 1, 0, 0, 0, 0, 0, 0, 0 ], "lt_st" => 0, "ver" => 1 }
  end
  let(:sensors) do
    { "sn" => { "Time" => "2026-10-31T10:00:00", "ENERGY" => { "TotalStartTime" => "2026-01-01T00:00:00", "Total" => 12.345, "Yesterday" => 0.5,
                                                               "Today" => 0.2, "Power" => 15, "ApparentPower" => 20, "Factor" => 0.75, "Voltage" => 221, "Current" => 0.09 },
                "AM2301" => { "Temperature" => 24.5, "Humidity" => 55.1 }, "TempUnit" => "C" }, "ver" => 1 }
  end
  let(:prefix) { "tasmota/discovery/AABBCCABCDEF" }

  def tasmota(*args) = ActsAsTenant.without_tenant { Mqtt::Tasmota.handle(*args) }

  def points = ActsAsTenant.with_tenant(tenant) { Device.find_by!(external_id: "AABBCCABCDEF").points.index_by(&:name) }

  it "configuração e sensores viram aparelho e pontos que o driver mqtt entende" do
    expect(Mqtt::Listener.topics).to include("tasmota/discovery/#")
    Mqtt::Listener.handle("#{prefix}/config", config.to_json)
    Mqtt::Listener.handle("#{prefix}/sensors", sensors.to_json)
    ps = points
    expect(ps.keys).to contain_exactly("Abajur", "Energia", "Energia hoje", "Potência", "Tensão", "Corrente", "Temperatura AM2301", "Umidade AM2301")
    relay = ps["Abajur"]
    expect(relay.address).to include("topic" => "stat/tasmota_ABCDEF/RESULT", "json_path" => "POWER", "command_topic" => "cmnd/tasmota_ABCDEF/POWER")
    expect(Drivers::Mqtt.value_for(relay, '{"POWER":"ON"}')).to be true
    expect(Drivers::Mqtt.payload(relay, false)).to eq("OFF")
    expect(ps["Energia"]).to have_attributes(unit: "kWh", state_class: "total_increasing", writable: false)
    expect(ps["Potência"].address).to eq("topic" => "tele/tasmota_ABCDEF/SENSOR", "json_path" => "ENERGY.Power")
    expect(Drivers::Mqtt.value_for(ps["Potência"], sensors["sn"].to_json)).to eq(15)

    # Idempotente: repetir não duplica.
    expect(tasmota("#{prefix}/config", config.to_json)).to eq(devices: 0, points: 0)
  end

  it "comando publica ON/OFF puro no tópico cmnd; luz com brilho ganha Dimmer" do
    allow(Mqtt::Listener).to receive(:publish)
    tasmota("#{prefix}/config", config.merge("rl" => [ 1, 2, 0, 0, 0, 0, 0, 0 ], "fn" => [], "lt_st" => 1).to_json)
    ps = points
    expect(ps.keys).to contain_exactly("Liga/desliga 1", "Liga/desliga 2", "Brilho")
    ActsAsTenant.with_tenant(tenant) do
      Drivers::Mqtt.new.execute(ps["Liga/desliga 2"], "on", nil)
      Drivers::Mqtt.new.execute(ps["Brilho"], "set", 40)
    end
    expect(Mqtt::Listener).to have_received(:publish).with("cmnd/tasmota_ABCDEF/POWER2", "ON")
    expect(Mqtt::Listener).to have_received(:publish).with("cmnd/tasmota_ABCDEF/Dimmer", "40")
    expect(Drivers::Mqtt.value_for(ps["Brilho"], '{"POWER2":"ON","Dimmer":40}')).to eq(40)
  end

  it "sensores antes da configuração esperam por ela" do
    tasmota("#{prefix}/sensors", sensors.to_json)
    expect(ActsAsTenant.with_tenant(tenant) { Device.count }).to eq(0)
    tasmota("#{prefix}/config", config.to_json)
    expect(points).to include("Potência")
  end

  it "retido vazio (aparelho saiu) é ignorado" do
    expect(tasmota("#{prefix}/config", "")).to be_nil
  end

  it "descobridor novo entra pelo registro, sem mudar o ouvinte (plugin falso)" do
    got = []
    fake = Module.new
    fake.define_singleton_method(:topics) { [ "falso/anuncia/#" ] }
    fake.define_singleton_method(:handles?) { |topic| topic.start_with?("falso/anuncia/") }
    fake.define_singleton_method(:handle) { |topic, payload| got << [ topic, payload ] }
    stub_const("Mqtt::FakeDiscovery", fake)
    stub_const("Mqtt::Listener::DISCOVERY", %w[Z2m Tasmota FakeDiscovery])
    expect(Mqtt::Listener.topics).to include("falso/anuncia/#", "tasmota/discovery/#", "zigbee2mqtt/bridge/devices")
    Mqtt::Listener.handle("falso/anuncia/x", "oi")
    expect(got).to eq([ %w[falso/anuncia/x oi] ])
  end

  it "plugin Tasmota no catálogo usa o driver mqtt" do
    stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[TasmotaPlugin])
    expect(Integrations.plugin("tasmota").driver).to eq("mqtt")
  end
end
