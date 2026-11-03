require "rails_helper"

# ondaC1 (C4): descoberta MQTT no formato `homeassistant/` (o do HA), com as
# abreviações, `~`, templates Jinja, formato de aparelho (`cmps`),
# disponibilidade e remoção. Sem broker: as mensagens vão direto ao descobridor.
RSpec.describe "Descoberta MQTT do HA (ondaC1, C4)" do
  let(:tenant) { create(:tenant) }
  let!(:site) { ActsAsTenant.with_tenant(tenant) { create(:site) } }
  let(:disc) { Mqtt::HaDiscovery }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def config(topic, payload) = disc.handle("homeassistant/#{topic}/config", payload.to_json)
  def device(id) = site.devices.find_by!(external_id: "mqtt-ha:#{id}")
  def pts(id) = device(id).points.reload.index_by { |p| p.address["discovery"] }

  it "entra no Listener como descobridor e assina config + disponibilidade" do
    expect(Mqtt::Listener.discoverers).to include(disc)
    expect(disc.topics).to include("homeassistant/+/+/config", "homeassistant/+/+/+/config")
    expect(disc.handles?("homeassistant/sensor/x/config")).to be true
    expect(disc.handles?("casa/sensor/x")).to be false
  end

  it "sensor com abreviações, ~ e value_template (Jinja do HA) vira medição com unidade e classe" do
    config("sensor/omg/temp", "~" => "home/OMG/BTtoMQTT/A4C138", "stat_t" => "~", "uniq_id" => "A4C138-temp", "name" => "Temperatura",
                              "unit_of_meas" => "°C", "dev_cla" => "temperature", "stat_cla" => "measurement",
                              "val_tpl" => "{{ value_json.tempc | float(0) | round(1) }}",
                              "dev" => { "ids" => [ "A4C138" ], "name" => "Teste Termômetro", "mf" => "Xiaomi", "mdl" => "LYWSD03MMC", "sw" => "1.2" })
    d = device("A4C138")
    expect(d).to have_attributes(name: "Teste Termômetro", manufacturer: "Xiaomi", model: "LYWSD03MMC", firmware: "1.2", driver: "mqtt")
    p = pts("A4C138")["sensor/omg/temp"]
    expect(p).to have_attributes(capability: "measure", unit: "°C", device_class: "temperature", state_class: "measurement", writable: false)
    expect(p.address["topic"]).to eq("home/OMG/BTtoMQTT/A4C138")
    expect(Drivers::Mqtt.value_for(p, '{"tempc":22.46,"hum":55}')).to eq(22.5)

    Mqtt::Listener.handle("home/OMG/BTtoMQTT/A4C138", '{"tempc":23.04}')
    expect(p.reload.value).to eq(23.0)
  end

  it "formato de aparelho (cmps): várias entidades de um aparelho, com o que é comum no topo" do
    config("device/teste01", "dev" => { "ids" => "teste01", "name" => "Teste Placa" }, "o" => { "name" => "Firmware X" },
                             "stat_t" => "teste01/state", "cmps" => {
                               "rele" => { "p" => "switch", "cmd_t" => "teste01/rele/set", "val_tpl" => "{{ value_json.rele }}" },
                               "porta" => { "p" => "binary_sensor", "dev_cla" => "door", "val_tpl" => "{{ value_json.porta }}" },
                               "desconhecido" => { "p" => "notify" }
                             })
    p = pts("teste01")
    expect(p.keys).to contain_exactly("switch/teste01/rele", "binary_sensor/teste01/porta")
    expect(p["binary_sensor/teste01/porta"].capability).to eq("contact")
    rele = p["switch/teste01/rele"]
    Mqtt::Listener.handle("teste01/state", '{"rele":"ON","porta":"OFF"}')
    expect([ rele.reload.value, p["binary_sensor/teste01/porta"].reload.value ]).to eq([ true, false ])

    allow(Mqtt::Listener).to receive(:publish)
    ExecuteCommandJob.perform_now(Points::Command.call(rele, "off", source: "web").id)
    expect(Mqtt::Listener).to have_received(:publish).with("teste01/rele/set", "OFF")
  end

  it "luz no esquema JSON: liga/desliga e brilho no mesmo tópico, escala 0–255 → 0–100" do
    config("light/teste_luz", "uniq_id" => "luz1", "schema" => "json", "stat_t" => "casa/luz", "cmd_t" => "casa/luz/set", "brightness" => true,
                              "dev" => { "ids" => [ "luz1" ], "name" => "Teste Luz" })
    p = pts("luz1")
    on, bri = p["light/teste_luz#state"], p["light/teste_luz#brightness"]
    expect([ on.capability, bri.capability ]).to eq(%w[onoff dimmer])
    Mqtt::Listener.handle("casa/luz", '{"state":"ON","brightness":255}')
    expect([ on.reload.value, bri.reload.value ]).to eq([ true, 100 ])
    expect(Drivers::Mqtt.payload(bri.reload, 50)).to eq('{"brightness":127}')
    expect(Drivers::Mqtt.payload(on, false)).to eq('{"state":"OFF"}')
  end

  it "cortina, fechadura (crítica), botão, número com command_template e clima" do
    dev = { "ids" => [ "multi" ], "name" => "Teste Multi" }
    config("cover/c1", "cmd_t" => "c/set", "stat_t" => "c/state", "pos_t" => "c/pos", "set_pos_t" => "c/pos/set", "pl_stop" => nil, "stat_open" => "aberta", "dev" => dev)
    config("lock/l1", "cmd_t" => "l/set", "stat_t" => "l/state", "dev" => dev)
    config("button/b1", "cmd_t" => "b/set", "pl_prs" => "GO", "dev" => dev)
    config("number/n1", "cmd_t" => "n/set", "cmd_tpl" => '{"alvo": {{ value }}}', "min" => 10, "max" => 30, "step" => 0.5, "dev" => dev)
    config("climate/ac", "mode_cmd_t" => "ac/mode/set", "modes" => %w[off cool], "temp_cmd_t" => "ac/temp/set", "temp_stat_t" => "ac/temp",
                         "curr_temp_t" => "ac/now", "dev" => dev)
    p = pts("multi")
    cmd = p["cover/c1#command"]
    expect(cmd).to have_attributes(capability: "enum", options: %w[open close])
    expect(Drivers::Mqtt.payload(cmd, "close")).to eq("CLOSE")
    state = p["cover/c1#state"]
    Mqtt::Listener.handle("c/state", "aberta")
    expect(state.reload.value).to eq("open")
    expect(p["cover/c1#position"]).to have_attributes(capability: "setpoint", unit: "%")
    lock = p["lock/l1"]
    expect(lock).to have_attributes(risk: "critical", options: %w[locked unlocked])
    expect(Drivers::Mqtt.payload(lock, "unlocked")).to eq("UNLOCK")
    Mqtt::Listener.handle("l/state", "LOCKED")
    expect(lock.reload.value).to eq("locked")
    expect(Drivers::Mqtt.payload(p["button/b1"], nil)).to eq("GO")
    expect(Drivers::Mqtt.payload(p["number/n1"], 21.5)).to eq('{"alvo": 21.5}')
    expect(p.keys).to include("climate/ac#mode", "climate/ac#target", "climate/ac#current")
    expect(p["climate/ac#mode"].options).to eq(%w[off cool])
  end

  it "disponibilidade liga e desliga o aparelho; payload vazio desativa a entidade" do
    config("sensor/s1", "stat_t" => "s1/state", "avty_t" => "s1/lwt", "pl_avail" => "Online", "pl_not_avail" => "Offline", "dev" => { "ids" => "s1", "name" => "Teste S1" })
    expect(disc.topics).to include("s1/lwt")
    expect(disc.handles?("s1/lwt")).to be true
    p = pts("s1")["sensor/s1"]
    disc.handle("s1/lwt", "Offline")
    expect([ device("s1").status, p.reload.quality ]).to eq(%w[offline unavailable])
    disc.handle("s1/lwt", "Online")
    expect([ device("s1").status, p.reload.quality ]).to eq(%w[online good])

    disc.handle("homeassistant/sensor/s1/config", "")
    expect(p.reload.disabled).to be true
    config("sensor/s1", "stat_t" => "s1/state", "dev" => { "ids" => "s1" }) # voltou
    expect(p.reload.disabled).to be false
  end

  it "não duplica o que já tem descoberta nativa (zigbee2mqtt, Tasmota) e é idempotente" do
    config("sensor/0x01/t", "stat_t" => "zigbee2mqtt/x", "o" => { "name" => "Zigbee2MQTT" }, "dev" => { "ids" => [ "zigbee2mqtt_0x01" ] })
    expect(site.devices.where("external_id LIKE 'mqtt-ha:%'")).to be_empty
    2.times { config("switch/r1", "cmd_t" => "r/set", "dev" => { "ids" => [ "r1" ] }) }
    expect(device("r1").points.count).to eq(1)
  end

  it "birth message ao conectar: aparelhos que seguem o HA reenviam a configuração" do
    client = instance_double(MQTT::Client, publish: true)
    disc.connected(client)
    expect(client).to have_received(:publish).with("homeassistant/status", "online", true)
  end

  it "componente novo entra por registro (stub_const), sem mudar o núcleo" do
    fake = Class.new(Mqtt::HaDiscovery::Components::Base) do
      describe key: "teste_vacuo"
      def self.points(c) = [ { name: "Teste Bateria", capability: "measure", unit: "%", writable: false, address: { "topic" => c["state_topic"] } } ]
    end
    stub_const("Mqtt::HaDiscovery::Components::TesteVacuo", fake)
    stub_const("Mqtt::HaDiscovery::COMPONENTS", Mqtt::HaDiscovery::COMPONENTS + %w[TesteVacuo])
    config("teste_vacuo/v1", "stat_t" => "v1/bat", "dev" => { "ids" => [ "v1" ], "name" => "Teste Robô" })
    expect(pts("v1")["teste_vacuo/v1"]).to have_attributes(name: "Teste Bateria", unit: "%")
  end
end
