require "rails_helper"

RSpec.describe Integrations do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:admin) { create(:user, tenant: tenant) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def entry(id, **extra)
    { "id" => id, "kind" => "tuya_local", "name" => "Aparelho #{id}", "manufacturer" => "Tuya", "secret" => "key-#{id}", "room" => "Sala",
      "address" => { "version" => "3.3" }, "points" => [ { "name" => "Liga/desliga", "capability" => "onoff", "address" => { "dps" => "1" } } ] }.merge(extra)
  end

  describe "plugins" do
    it "catálogo vem do registro, com interface comum" do
      expect(described_class.plugins.map(&:key)).to eq(%w[tuya xiaomi alexa camera hikvision mqtt zigbee2mqtt esphome shelly tasmota matter cast webos tizen adb broadlink spotify frigate reolink unifi_protect hue wled yeelight switchbot daikin midea lg_thinq sunspec growatt dirigera sonos govee zwave_js ble_proxy calendar weather mobile_app network_tracker telegram whatsapp http_messenger system ha_import home_assistant])
      expect(described_class.drivers).to eq(%w[tuya xiaomi alexa camera hikvision mqtt esphome shelly matter cast webos tizen adb broadlink spotify frigate reolink unifi_protect hue wled yeelight switchbot daikin midea lg_thinq sunspec growatt dirigera sonos govee zwave_js ble_proxy calendar weather mobile_app network_tracker telegram whatsapp http_messenger system home_assistant])
      expect(described_class.for_driver("mqtt")).to eq(Integrations::MqttPlugin)
      expect(described_class.plugin("zigbee2mqtt").driver).to eq("mqtt")
      described_class.plugins.each { |p| expect([ p.title, p.icon, p.description ]).to all(be_present) }
      expect { Integrations::Plugin.setup(site, {}) }.to raise_error(NotImplementedError)
      expect { Integrations::Plugin.inventory(nil) }.to raise_error(NotImplementedError)
      expect(Integrations::Plugin.connect_locals(nil, {})).to eq({})
      expect(Integrations::Plugin.logged_in?(nil)).to be false
      expect(Integrations::Plugin.login(:i, {}).to).to eq(:connect)
      expect(Integration.new(driver: "zzz").driver_label).to eq("zzz")
    end
  end

  describe ".sync! e .adopt!" do
    let(:integration) { site.integrations.create!(driver: "tuya", name: "Smart Life", status: "ok", credentials: { "x" => 1 }.to_json) }

    before { admin }

    it "não duplica o aparelho já importado (device_id), liga à conta, troca a chave e marca o que sumiu" do
      old = create(:device, site: site, driver: "tuya_local", external_id: "a1", credential: "velha", address: { "host" => "10.0.0.5", "version" => "3.4" })
      gone = create(:device, site: site, driver: "tuya_local", external_id: "z9", integration: integration)
      allow(Integrations::TuyaPlugin).to receive(:inventory).and_return([ entry("a1"), entry("b2"), entry("c3", "sub" => true) ])

      r = described_class.sync!(integration)
      expect(r).to include(found: 3, keys: 1, removed: 1)
      expect(old.reload).to have_attributes(integration_id: integration.id, credential: "key-a1", removed_at: nil)
      expect(old.address).to eq("host" => "10.0.0.5", "version" => "3.4")
      expect(gone.reload.removed_at).to be_present
      expect(integration.reload).to have_attributes(status: "ok", last_ok_at: be_present)
      expect(described_class.pending(integration).map { |e| e["id"] }).to eq(%w[b2 c3]) # sub-dispositivo do hub também entra (nuvem)
      expect(Notification.count).to eq(0) # primeira varredura: a pessoa está olhando a lista

      allow(Integrations::TuyaPlugin).to receive(:inventory).and_return([ entry("a1"), entry("b2"), entry("d4", "name" => "Lâmpada nova"), entry("z9") ])
      r = described_class.sync!(integration)
      expect(r).to include(fresh: 1, removed: 0, keys: 1) # z9 voltou e ganhou a chave da conta
      expect(gone.reload.removed_at).to be_nil
      expect(Notification.sole).to have_attributes(kind: "integracao", title: "Novo dispositivo encontrado")
      expect(Notification.sole.body).to include("Lâmpada nova")
      expect(site.devices.where(external_id: "a1").count).to eq(1)
    end

    it "adota com a área escolhida (ou nova pelo cômodo), pontos e chave únicos" do
      sala = create(:area, site: site, name: "Sala")
      create(:device, site: site, name: "Aparelho b2").points.create!(name: "Liga/desliga", capability: "onoff", site: site)
      integration.update!(inventory: [ entry("b2"), entry("c3", "room" => "Cozinha"), entry("d4", "sub" => true), entry("e5") ].to_json)
      expect(described_class.suggest_area(site, "sala ")).to eq(sala.id)
      expect(described_class.suggest_area(site, "Cozinha")).to eq("new:Cozinha")
      expect(described_class.suggest_area(site, nil)).to eq("")

      n = described_class.adopt!(integration, "b2" => sala.id, "c3" => "new:Cozinha", "d4" => "", "e5" => "", "zz" => "")
      expect(n).to eq(4)
      b2 = site.devices.find_by!(external_id: "b2")
      expect(b2).to have_attributes(area: sala, integration: integration, credential: "key-b2", driver: "tuya_local", poll_s: 1800)
      expect(b2.points.sole.key).to eq("aparelho_b2.liga_desliga_2")
      expect(site.devices.find_by!(external_id: "c3").area.name).to eq("Cozinha")
      expect(site.devices.find_by!(external_id: "e5").area).to be_nil
      expect(site.devices.find_by(external_id: "d4")).to be_present
      expect(described_class.adopt!(integration, "b2" => "")).to eq(0)
    end

    it "erro na conta fica na integração e sobe" do
      allow(Integrations::TuyaPlugin).to receive(:inventory).and_raise(Tuya::Cloud::Error, "token invalid")
      expect { described_class.sync!(integration) }.to raise_error(Tuya::Cloud::Error)
      expect(integration.reload).to have_attributes(status: "error", last_error: "token invalid")
      expect { described_class.sync!(site.integrations.new(driver: "zzz")) }.to raise_error(Integrations::Error, /plugin/)
    end

    it "MQTT liga os aparelhos do broker ao card; câmera casa pelo IP" do
      mqtt = site.integrations.create!(driver: "mqtt", name: "MQTT")
      d = create(:device, site: site, driver: "mqtt", external_id: "0x1")
      expect(described_class.sync!(mqtt)).to include(found: 1)
      expect(d.reload.integration).to eq(mqtt)

      dvr = create(:device, site: site, driver: "go2rtc", address: { "host" => "10.0.0.9" })
      cam = site.integrations.create!(driver: "hikvision", name: "DVR", settings: { "host" => "10.0.0.9" }, credentials: { "password" => "p" }.to_json)
      allow(Isapi).to receive(:inventory).and_return([ { "id" => "10.0.0.9", "kind" => "go2rtc", "match" => "host", "name" => "DVR", "points" => [] } ])
      described_class.sync!(cam)
      expect(dvr.reload).to have_attributes(integration_id: cam.id, external_id: "10.0.0.9", credential: nil)
      expect(described_class.matched_ids(cam)).to include("10.0.0.9")
    end
  end
end

RSpec.describe Miio::Spec do
  before { Rails.cache.clear }

  it "propriedades MIoT pelo mapa de dados; robô pelo Miio::Vacuum; sem rede = sem pontos" do
    stub_request(:get, "https://miot-spec.org/miot-spec-v2/instances?status=all").to_return(body: { instances: [
      { model: "yeelink.light.x", type: "urn:miot-spec-v2:device:light:0000A001:yeelink-x:1", version: 1 },
      { model: "yeelink.light.x", type: "urn:miot-spec-v2:device:light:0000A001:yeelink-x:2", version: 2 }
    ] }.to_json)
    stub_request(:get, /instance\?type=urn.*yeelink-x.2/).to_return(body: { services: [
      { iid: 2, description: "Light", properties: [
        { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:yeelink-x:1", access: %w[read write notify] },
        { iid: 2, type: "urn:miot-spec-v2:property:brightness:0000000D:yeelink-x:1", access: %w[read write], "value-range": [ 1, 100, 1 ] },
        { iid: 3, type: "urn:miot-spec-v2:property:mode:0000000D:yeelink-x:1", access: %w[read write] }
      ] },
      { iid: 3, description: "Sensor", properties: [
        { iid: 1, type: "urn:miot-spec-v2:property:temperature:00000020:yeelink-x:1", access: %w[read] },
        { iid: 2, type: "urn:miot-spec-v2:property:on:00000006:yeelink-x:1", access: %w[read] }
      ] }
    ] }.to_json)
    pts = described_class.points("yeelink.light.x")
    expect(pts.map { |p| [ p["name"], p["capability"], p["address"] ] }).to eq([
      [ "Liga/desliga Light", "onoff", { "siid" => 2, "piid" => 1 } ], [ "Brilho", "dimmer", { "siid" => 2, "piid" => 2 } ],
      [ "Temperatura", "measure", { "siid" => 3, "piid" => 1 } ]
    ])
    expect(pts[1]).to include("scale" => 1.0, "min" => 1, "max" => 100)
    expect(described_class.points("modelo.desconhecido")).to eq([])
    expect(described_class.points("xiaomi.vacuum.d109gl").first).to include("capability" => "vacuum")

    Rails.cache.clear
    stub_request(:get, "https://miot-spec.org/miot-spec-v2/instances?status=all").to_return(status: 500)
    expect(described_class.points("yeelink.light.x")).to eq([])
  end
end

RSpec.describe Isapi do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:integration) do
    site.integrations.create!(driver: "hikvision", name: "DVR", settings: { "host" => "10.0.0.9", "username" => "admin" }, credentials: { "password" => "senha" }.to_json)
  end
  let(:challenge) { { status: 401, headers: { "WWW-Authenticate" => 'Digest realm="DVR", qop="auth", nonce="N1", opaque="O"' } } }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def digest_ok?(req, path)
    p = req.headers["Authorization"].to_s.sub("Digest ", "").scan(/(\w+)="?([^",]*)"?/).to_h
    ha1 = Digest::MD5.hexdigest("admin:DVR:senha")
    ha2 = Digest::MD5.hexdigest("GET:#{path}")
    p["response"] == Digest::MD5.hexdigest([ ha1, "N1", p["nc"], p["cnonce"], "auth", ha2 ].join(":"))
  end

  def stub_isapi(path, body)
    stub_request(:get, "http://10.0.0.9/#{path.delete_prefix('/')}").to_return(lambda do |req|
      req.headers["Authorization"] ? (digest_ok?(req, path) ? { body: body } : { status: 401 }) : challenge
    end)
  end

  it "lê nome, modelo e os substreams com Digest" do
    stub_isapi("/ISAPI/System/deviceInfo", '<DeviceInfo xmlns="http://www.hikvision.com/ver20/XMLSchema"><deviceName>DVR Casa</deviceName><model>DS-7208</model></DeviceInfo>')
    stub_isapi("/ISAPI/Streaming/channels", <<~XML)
      <StreamingChannelList xmlns="http://www.hikvision.com/ver20/XMLSchema">
        <StreamingChannel><id>101</id><channelName>Garagem</channelName><enabled>true</enabled></StreamingChannel>
        <StreamingChannel><id>102</id><channelName>Garagem</channelName><enabled>true</enabled></StreamingChannel>
        <StreamingChannel><id>202</id><channelName></channelName><enabled>true</enabled></StreamingChannel>
        <StreamingChannel><id>302</id><channelName>Off</channelName><enabled>false</enabled></StreamingChannel>
      </StreamingChannelList>
    XML
    dvr = described_class.inventory(integration).sole
    expect(dvr).to include("id" => "10.0.0.9", "kind" => "go2rtc", "match" => "host", "name" => "DVR Casa", "model" => "DS-7208",
                           "address" => { "host" => "10.0.0.9", "port" => 554, "username" => "admin" })
    expect(dvr["points"].map { |p| [ p["name"], p["address"]["path"] ] }).to eq([ [ "Garagem", "/Streaming/Channels/102" ], [ "Câmera 2", "/Streaming/Channels/202" ] ])
  end

  it "senha errada e DVR fora do ar viram Error" do
    integration.update!(credentials: { "password" => "errada" }.to_json)
    stub_isapi("/ISAPI/System/deviceInfo", "<x/>")
    expect { described_class.inventory(integration) }.to raise_error(Isapi::Error, /não conferem/)
    stub_request(:get, %r{10.0.0.9/ISAPI}).to_return(status: 500)
    expect { described_class.inventory(integration) }.to raise_error(Isapi::Error, /500/)
    stub_request(:get, %r{10.0.0.9/ISAPI}).to_raise(Errno::EHOSTUNREACH)
    expect { described_class.inventory(integration) }.to raise_error(Isapi::Error, /Sem conexão/)
  end
end
