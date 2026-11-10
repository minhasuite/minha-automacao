require "rails_helper"

# Lote 6: Tuya pela nuvem como no HA (sub-dispositivos do hub, estado,
# comando por código, MQTT em tempo real, eventos de botão) com um servidor
# falso que confere a assinatura do SDK (GET e POST) e um cliente MQTT falso.
RSpec.describe "Tuya na nuvem (Lote 6)" do # rubocop:disable RSpec/DescribeClass
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:endpoint) { "https://apigw.tuyaus.com" }
  let(:integration) do
    site.integrations.create!(driver: "tuya", name: "Smart Life", status: "ok", credentials: {
      "user_code" => "abc", "endpoint" => endpoint,
      "token" => { "t" => (Time.now.to_f * 1000).to_i, "expire_time" => 7200, "access_token" => "AT", "refresh_token" => "RT" }
    }.to_json)
  end
  let(:posted) { [] }
  # Conta com hub Zigbee (chave própria), 2 filhos Zigbee (outra chave), controle IR com TV e um Wi-Fi.
  let(:account) do
    {
      "/v1.0/m/life/users/homes" => [ { "ownerId" => 9 } ],
      %(/v1.0/m/life/ha/home/devices?{"homeId":"9"}) => [
        { "id" => "hub", "name" => "Hub", "category" => "wg2", "sub" => true, "local_key" => "kh", "online" => true, "status" => [ { "code" => "master_state", "value" => "normal" } ] },
        { "id" => "btn", "name" => "Botão", "category" => "wxkg", "sub" => true, "local_key" => "kz", "online" => true,
          "status" => [ { "code" => "switch_mode1", "value" => "click" }, { "code" => "battery_percentage", "value" => 90 } ] },
        { "id" => "pir", "name" => "Movimento", "category" => "pir", "sub" => true, "local_key" => "kz", "online" => false, "status" => [ { "code" => "pir", "value" => "pir" } ] },
        { "id" => "irhub", "name" => "IR", "category" => "wnykq", "sub" => false, "local_key" => "ki", "online" => true, "status" => [] },
        { "id" => "tv", "name" => "TV", "category" => "infrared_tv", "sub" => true, "local_key" => "ki", "online" => true, "status" => [] },
        { "id" => "plug", "name" => "Tomada", "category" => "cz", "sub" => false, "local_key" => "kp", "online" => true,
          "status" => [ { "code" => "switch_1", "value" => true }, { "code" => "add_ele", "value" => 25 } ] }
      ],
      "/v1.0/m/life/devices/hub/status" => { "dpStatusRelationDTOS" => [ rel(32, "master_state", "Enum", range: %w[normal alarm]), rel(34, "factory_reset", "Boolean") ] },
      "/v1.1/m/life/hub/specifications" => { "functions" => [ { "code" => "master_state" }, { "code" => "factory_reset" } ] },
      "/v1.0/m/life/devices/btn/status" => { "dpStatusRelationDTOS" => [ rel(1, "switch_mode1", "Enum", range: %w[click double_click press]),
                                                                         rel(10, "battery_percentage", "Integer", unit: "%", scale: 0) ] },
      "/v1.0/m/life/devices/pir/status" => { "dpStatusRelationDTOS" => [ rel(1, "pir", "Enum", range: %w[pir none]) ] },
      "/v1.0/m/life/devices/plug/status" => { "dpStatusRelationDTOS" => [
        rel(1, "switch_1", "Boolean"), rel(17, "add_ele", "Integer", scale: 3), rel(22, "voltage_coe", "Integer"), rel(41, "child_lock", "Boolean")
      ] },
      "/v1.1/m/life/plug/specifications" => { "functions" => [ { "code" => "switch_1" }, { "code" => "child_lock" } ] }
    }.tap { |h| %w[btn pir irhub tv].each { |d| h["/v1.1/m/life/#{d}/specifications"] ||= {} } }
     .tap { |h| %w[irhub tv].each { |d| h["/v1.0/m/life/devices/#{d}/status"] = "" } }
     .tap { |h| %w[hub btn pir irhub tv plug].each { |d| h["/v1.0/m/thing/ha/#{d}/room"] = { "name" => "Sala" } } }
  end

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def rel(dp, code, type, desc = {}) = { "dpId" => dp, "statusCode" => code, "valueType" => type, "valueDesc" => desc.to_json }

  # GET e POST cifrados como no SDK; confere X-sign com query + corpo; guarda o corpo dos POST.
  def fake_cloud(results)
    stub_request(:any, /#{Regexp.escape(endpoint)}/).to_return(lambda do |req|
      rid = req.headers["X-Requestid"]
      hash_key = Digest::MD5.hexdigest("#{rid}RT")
      secret = Tuya::Cloud.secret(rid, hash_key)
      query = CGI.parse(URI(req.uri.to_s).query.to_s)["encdata"]&.first.to_s
      data = req.body.present? ? JSON.parse(req.body)["encdata"].to_s : ""
      headers = { "X-appKey" => req.headers["X-Appkey"], "X-requestId" => rid, "X-sid" => "", "X-time" => req.headers["X-Time"], "X-token" => req.headers["X-Token"] }
      raise "assinatura errada" unless req.headers["X-Sign"] == Tuya::Cloud.sign(hash_key, headers, query + data)

      path = URI(req.uri.to_s).path
      posted << [ path, JSON.parse(Tuya::Cloud.decrypt(data, secret)) ] if data.present?
      params = query.present? ? JSON.parse(Tuya::Cloud.decrypt(query, secret)) : {}
      result = results.fetch(path) { |p| results.fetch("#{p}?#{params.to_json}") }
      { body: { success: true, result: Tuya::Cloud.encrypt(result.to_json, secret) }.to_json }
    end)
  end


  def adopt_all
    Integrations.sync!(integration)
    Integrations.adopt!(integration, Integrations.pending(integration).to_h { |e| [ e["id"], "" ] })
  end

  it "varre como o HA: sub-dispositivo ligado ao hub (via), estado, código do dp e mapa das categorias" do
    fake_cloud(account)
    list = Tuya::Cloud.new(integration).inventory.index_by { |e| e["id"] }
    expect(list["hub"]).to include("kind" => "tuya_cloud", "sub" => false, "match_drivers" => %w[tuya_cloud tuya_local], "poll_s" => 0)
    expect(list["btn"]["address"]).to eq("via" => "hub")           # Zigbee: o único hub sem filho na própria chave
    expect(list["tv"]["address"]).to eq("via" => "irhub")          # IR: mesma chave do controle
    expect(list["plug"]["address"]).to eq({})
    expect(list["btn"]["state"]).to eq("switch_mode1" => "click", "battery_percentage" => 90)

    hub = list["hub"]["points"].sole
    expect(hub).to include("name" => "Hub com problema", "capability" => "problem", "writable" => false)
    expect(hub["address"]).to include("code" => "master_state", "decode" => "value", "match" => "alarm", "unmatched" => false) # factory_reset nunca vira ponto
    btn = list["btn"]["points"].index_by { |p| p["name"] }
    expect(btn["Botão 1"]).to include("capability" => "event", "options" => %w[click double_click press])
    expect(btn["Botão 1"]["address"]).to include("code" => "switch_mode1", "push_only" => true)
    expect(list["pir"]["points"].sole).to include("capability" => "motion")
    plug = list["plug"]["points"].index_by { |p| p["name"] }
    expect(plug.keys).to contain_exactly("Liga/desliga", "Energia", "Trava infantil") # calibração (_coe) fora
    expect(plug["Energia"]).to include("unit" => "kWh", "state_class" => "total_increasing", "device_class" => "energy")
    expect(list["tv"]["points"]).to eq([])
  end

  it "adota os Zigbee do hub, grava o estado inicial e comanda pela nuvem por código do dp" do
    fake_cloud(account.merge("/v1.1/m/thing/plug/commands" => true))
    expect(adopt_all).to eq(6)
    btn = site.devices.find_by!(external_id: "btn")
    expect(btn).to have_attributes(driver: "tuya_cloud", address: { "via" => "hub" }, poll_s: 0, status: "online")
    expect(btn.points.find_by!(name: "Bateria").value).to eq(90)
    expect(btn.points.find_by!(name: "Botão 1").value).to be_nil # estado completo não conta como clique
    pir = site.devices.find_by!(external_id: "pir")
    expect(pir.points.sole).to have_attributes(quality: "unavailable") # fora do ar na nuvem

    plug = site.devices.find_by!(external_id: "plug").points.find_by!(name: "Liga/desliga")
    expect(plug.value).to be true
    Drivers.for(plug.device).execute(plug, "off", nil)
    expect(posted.last).to eq([ "/v1.1/m/thing/plug/commands", { "commands" => [ { "code" => "switch_1", "value" => false } ] } ])
    expect(plug.reload.value).to be false
    expect { Drivers::TuyaCloud.new.execute(btn.points.find_by!(name: "Bateria").tap { |p| p.address.delete("code") }, "set", 1) }
      .to raise_error(Drivers::TuyaCloud::Error, /código/)
    expect { Drivers::TuyaCloud.cloud_for(Device.new) }.to raise_error(Drivers::TuyaCloud::Error, /conta/)
  end

  it "LocalTuya já importado não duplica: liga à conta, ganha o código, comanda local; sem IP vai pela nuvem" do
    local = create(:device, site: site, driver: "tuya_local", external_id: "plug", name: "Tomada LAN", credential: "velha",
                            address: { "host" => "10.0.0.7", "version" => "3.3" })
    lp = local.points.create!(name: "Liga", capability: "onoff", site: site, address: { "dps" => "1" })
    fake_cloud(account.merge("/v1.1/m/thing/plug/commands" => true))
    Integrations.sync!(integration)
    expect(Integrations.pending(integration).map { |e| e["id"] }).not_to include("plug")
    expect(site.devices.where(external_id: "plug").count).to eq(1)
    expect(local.reload).to have_attributes(integration: integration, credential: "kp")
    expect(lp.reload.address).to eq("dps" => "1", "code" => "switch_1")
    expect(lp.value).to be true # estado da nuvem no aparelho local

    conn = instance_double(Tuya::Connection, set: true, status: { "1" => false }, close: nil)
    allow(Drivers::TuyaLocal).to receive(:connection_for).and_return(instance_double(Tuya::Connection, connect: conn))
    Drivers.for(local).execute(lp, "off", nil)
    expect(conn).to have_received(:set).with("1" => false)
    expect(posted).to be_empty

    local.update!(address: {})
    Drivers.for(local).execute(lp.reload, "on", nil)
    expect(posted.last.last).to eq("commands" => [ { "code" => "switch_1", "value" => true } ])
  end

  describe Tuya::CloudListener do
    before do
      fake_cloud(account.merge("/v1.0/m/life/ha/access/config" => {
        "url" => "ssl://m1.tuyaus.com:8883", "clientId" => "cid", "username" => "u", "password" => "p", "expireTime" => 7200,
        "topic" => { "devId" => { "sub" => "smart/device/out/{devId}" } }
      }))
      adopt_all
    end

    let(:btn) { site.devices.find_by!(external_id: "btn") }

    def msg(protocol, data) = { "protocol" => protocol, "data" => data }.to_json

    it "clique repetido é evento a cada vez; dpId e código; online/offline" do
      click = site.automations.create!(name: "Clique")
      click.publish!({ "triggers" => [ { "type" => "state", "point" => btn.points.find_by!(name: "Botão 1").id, "to" => "double_click" } ],
                      "actions" => [ { "type" => "set", "var" => "n", "expr" => "1" } ] })
      click.update!(enabled: true)
      2.times { described_class.handle(integration, msg(4, "devId" => "btn", "status" => [ { "dpId" => 1, "value" => "double_click" } ])) }
      expect(click.runs.count).to eq(2)
      described_class.handle(integration, msg(4, "devId" => "btn", "status" => [ { "code" => "battery_percentage", "value" => 40 } ]))
      expect(btn.points.find_by!(name: "Bateria").value).to eq(40)

      described_class.handle(integration, msg(20, "bizCode" => "offline", "bizData" => { "devId" => "btn" }))
      expect(btn.points.find_by!(name: "Bateria").quality).to eq("unavailable")
      described_class.handle(integration, msg(20, "bizCode" => "online", "bizData" => { "devId" => "btn" }))
      expect(btn.reload.status).to eq("online")
      expect(described_class.handle(integration, "não é json")).to be_nil
      expect(described_class.handle(integration, msg(4, "devId" => "outro"))).to be_nil
    end

    it "sessão: credencial do MQTT da conta, TLS, assina os aparelhos, lê e cai para indisponível" do
      queue = [ [ "smart/device/out/pir", msg(4, "devId" => "pir", "status" => [ { "dpId" => 1, "value" => "none" } ]) ] ]
      client = instance_double(MQTT::Client, subscribe: true, disconnect: nil)
      allow(client).to receive(:queue_empty?) { queue.empty? ? raise(MQTT::ProtocolException, "caiu") : false }
      allow(client).to receive(:get) { queue.shift }
      allow(MQTT::Client).to receive(:connect).and_return(client)

      expect(described_class.integration_ids).to eq([ integration.id ])
      expect(described_class.session(integration.id)).to be true
      expect(MQTT::Client).to have_received(:connect).with(hash_including(host: "m1.tuyaus.com", port: 8883, ssl: true, client_id: "cid", username: "u", password: "p"))
      expect(client).to have_received(:subscribe).with("smart/device/out/btn" => 1)
      expect(posted.map(&:first)).to include("/v1.0/m/life/ha/access/config")
      pir = site.devices.find_by!(external_id: "pir").points.sole
      expect(pir.value).to be false # "none" → sem movimento
      expect(pir.quality).to eq("unavailable") # a sessão caiu
      expect(described_class.session(SecureRandom.uuid)).to be true # integração sumiu: nada a ouvir
    end

    it "erro passageiro de rede não desliga o tempo real; conectar volta a integração para ok; erro de login para" do
      integration.error!(Integrations::Error.new("Sem conexão com a Tuya (OpenTimeout)."))
      expect(described_class.integration_ids).to eq([ integration.id ]) # continua tentando
      client = instance_double(MQTT::Client, subscribe: true, disconnect: nil)
      allow(client).to receive(:queue_empty?).and_raise(MQTT::ProtocolException, "caiu")
      allow(MQTT::Client).to receive(:connect).and_return(client)
      described_class.session(integration.id)
      expect(integration.reload).to have_attributes(status: "ok", last_error: nil)
      integration.error!(Integrations.auth(Integrations::Error.new("login vencido")))
      expect(described_class.integration_ids).to eq([]) # credencial: espera a pessoa entrar de novo
    end

    it "supervisor liga uma thread por integração com aparelho e encerra a que saiu" do
      allow(described_class).to receive(:listen)
      described_class.scan
      expect(described_class.instance_variable_get(:@threads).keys).to eq([ integration.id ])
      site.devices.update_all(removed_at: Time.current)
      described_class.scan
      expect(described_class.instance_variable_get(:@threads).keys).to eq([])
    end
  end

  # Aberto/fechado: categoria, família de códigos, decodificador e plugin novos sem mudar o núcleo.
  describe "extensão por dados e registro" do
    it "padrão e decodificador falsos no mapa viram ponto sem código novo" do
      map = Tuya::Cloud::MAP.merge("patterns" => [ { "match" => "\\Axyz_(\\d+)\\z", "name" => "Canal %{1}", "capability" => "motion",
                                                     "decode" => "inverso" } ],
                                   "codes" => Tuya::Cloud::MAP["codes"].merge("abc" => { "name" => "Evento falso", "capability" => "event", "push_only" => true }))
      stub_const("Tuya::Cloud::MAP", map)
      stub_const("Points::Decode::DECODERS", Points::Decode::DECODERS.merge("inverso" => ->(raw) { !raw }))
      pts = Tuya::Cloud.points("X", [ rel(7, "xyz_3", "Boolean"), rel(8, "abc", "Enum", range: %w[a b]) ], []).index_by { |p| p["name"] }
      expect(pts["Canal 3"]).to include("capability" => "motion")
      expect(pts["Canal 3"]["address"]).to include("decode" => "inverso", "code" => "xyz_3")
      expect(Point.new(capability: "motion", address: pts["Canal 3"]["address"]).from_raw(false)).to be true
      expect(pts["Evento falso"]).to include("capability" => "event", "options" => %w[a b])
    end

    it "plugin falso com match_drivers casa aparelho de outro driver sem duplicar" do
      fake = Class.new(Integrations::Plugin) do
        describe key: "falso", title: "Falso", icon: "link", description: "Teste", driver: "tuya"
        def self.inventory(_i) = [ { "id" => "x1", "kind" => "tuya_cloud", "match_drivers" => %w[tuya_cloud mqtt], "name" => "X", "points" => [] } ]
      end
      stub_const("Integrations::FalsoPlugin", fake)
      stub_const("Integrations::PLUGINS", %w[FalsoPlugin] + Integrations::PLUGINS)
      d = create(:device, site: site, driver: "mqtt", external_id: "x1")
      Integrations.sync!(integration)
      expect(d.reload.integration).to eq(integration)
      expect(Integrations.pending(integration)).to eq([])
    end
  end
end
