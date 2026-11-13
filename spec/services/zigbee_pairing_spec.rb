require "rails_helper"

# Assistente de pareamento Zigbee, renome que chega ao z2m e saúde/mapa da
# rede (Pairing, Mqtt::Z2m::Bridge). Broker falso: nada sai para a rede.
RSpec.describe "Pareamento Zigbee (Pairing + Mqtt::Z2m::Bridge)" do
  let(:tenant) { create(:tenant) }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:broker) { FakeMqttBroker.install(self) }
  let(:bridge) { Mqtt::Z2m::Bridge }
  let(:devices_json) { file_fixture("z2m_bridge_devices.json").read }

  around { |ex| within(tenant) { ex.run } }

  def z2m_device(ieee:, name:, type: "EndDevice", power: "Battery", exposes: nil, model: "SNZB-04")
    exposes ||= [ { "type" => "binary", "name" => "contact", "property" => "contact", "access" => 1, "value_on" => false, "value_off" => true },
                  { "type" => "numeric", "name" => "battery", "property" => "battery", "access" => 1, "unit" => "%" } ]
    { "ieee_address" => ieee, "type" => type, "friendly_name" => name, "network_address" => 4242, "power_source" => power, "interview_completed" => true,
      "definition" => { "model" => model, "vendor" => "SONOFF", "description" => "Contato", "exposes" => exposes } }
  end

  def publish_devices(*list) = broker.deliver("zigbee2mqtt/bridge/devices", list)
  def event(type, data) = broker.deliver("zigbee2mqtt/bridge/event", { type: type, data: data })

  describe "descoberta com a ponte" do
    it "marca o aparelho da ponte, papel, alimentação e o ponto de bateria" do
      broker.deliver("zigbee2mqtt/bridge/devices", devices_json)
      d = site.devices.find_by!(external_id: "0xa4c138f1d2b4e5f1")
      expect(d.address).to include("bridge" => "zigbee2mqtt", "topic" => "zigbee2mqtt/sala_temperatura", "friendly_name" => "sala_temperatura")
      expect(Pairing.mesh(d)).to include("role" => "end_device", "power" => "battery")
      expect(d.battery_point_id).to eq(d.points.find_by("points.address->>'json_path' = 'battery'").id)
      expect(site.devices.find_by!(external_id: "0xa4c1380b7e6f5d4c").address.dig("mesh", "role")).to eq("router")
      expect(bridge.owns?(d)).to be true
      expect(Pairing.for_device(d)).to eq(bridge)
      expect(bridge.available?(site)).to be true
    end

    it "não fica disponível sem broker ou fora do local do z2m" do
      allow(Drivers::Mqtt).to receive(:url).and_return(nil)
      expect(bridge.available?(site)).to be false
      expect(Pairing.for_site(site)).to eq([])
    end
  end

  describe "eventos da ponte" do
    it "entrou → entrevista → descoberto (liga ao aparelho) → saiu" do
      event("device_joined", { "ieee_address" => "0x1", "friendly_name" => "0x1" })
      join = PairingJoin.find_by!(external_id: "0x1")
      expect(join).to have_attributes(status: "joined", protocol: "zigbee2mqtt", name: "0x1")

      event("device_interview", { "ieee_address" => "0x1", "friendly_name" => "0x1", "status" => "started" })
      expect(join.reload.status).to eq("interviewing")
      event("device_interview", { "ieee_address" => "0x1", "friendly_name" => "0x1", "status" => "successful", "supported" => true,
                                  "definition" => { "model" => "SNZB-04", "vendor" => "SONOFF", "description" => "Contato" } })
      expect(join.reload).to have_attributes(status: "successful", model: "SNZB-04", manufacturer: "SONOFF", supported: true)
      expect(join.ready?).to be false

      expect(Mqtt::Listener).to receive(:rescan!).and_call_original
      publish_devices(z2m_device(ieee: "0x1", name: "0x1"))
      expect(join.reload.device).to eq(site.devices.find_by!(external_id: "0x1"))
      expect(join).to have_attributes(power_source: "Battery", battery?: true)
      expect(join.ready?).to be true

      event("device_leave", { "ieee_address" => "0x1" })
      expect(join.reload.status).to eq("left")
      event("device_announce", { "ieee_address" => "0x1" })
      event("device_leave", { "ieee_address" => "0x9" })
      expect(PairingJoin.count).to eq(1)
    end

    it "entrevista que falhou e reentrada recomeçam a decisão" do
      event("device_interview", { "ieee_address" => "0x2", "status" => "failed" })
      join = PairingJoin.find_by!(external_id: "0x2")
      expect(join.status).to eq("failed")
      join.resolve!("dismissed")
      event("device_joined", { "ieee_address" => "0x2", "friendly_name" => "0x2" })
      expect(join.reload).to have_attributes(status: "joined", resolution: nil)
      broker.deliver("zigbee2mqtt/bridge/event", "não é json")
    end

    it "info, estado e resposta do permit_join mantêm o prazo do pareamento" do
      ends = 3.minutes.from_now
      broker.deliver("zigbee2mqtt/bridge/info", { version: "2.6.0", permit_join: true, permit_join_end: (ends.to_f * 1000).to_i,
                                                  coordinator: { type: "EmberZNet", ieee_address: "0xc", meta: { revision: "7.4" } }, network: { channel: 25, pan_id: 1 }, config: { huge: true } })
      b = PairingBridge.find_by!(site: site, protocol: "zigbee2mqtt")
      expect(b.open?).to be true
      expect(b.permit_until).to be_within(1).of(ends)
      expect(b.info).to include("version" => "2.6.0", "network" => { "channel" => 25, "pan_id" => 1 })
      expect(b.info).not_to have_key("config")

      broker.deliver("zigbee2mqtt/bridge/info", { permit_join: true, permit_join_timeout: 30 })
      expect(b.reload.seconds_left).to be_between(28, 30)
      broker.deliver("zigbee2mqtt/bridge/info", { permit_join: true })
      expect(b.reload.open?).to be true
      broker.deliver("zigbee2mqtt/bridge/info", { permit_join: false })
      expect(b.reload.open?).to be false

      broker.deliver("zigbee2mqtt/bridge/response/permit_join", { data: { time: 120 }, status: "ok" })
      expect(b.reload.seconds_left).to be_between(118, 120)
      broker.deliver("zigbee2mqtt/bridge/response/permit_join", { data: { value: false, time: 0 }, status: "ok" })
      expect(b.reload.open?).to be false
      broker.deliver("zigbee2mqtt/bridge/response/permit_join", { data: {}, status: "error", error: "sem coordenador" })
      expect(b.reload.info["error"]).to eq("sem coordenador")

      broker.deliver("zigbee2mqtt/bridge/state", { state: "offline" })
      expect(b.reload.online?).to be false
      broker.deliver("zigbee2mqtt/bridge/state", "online")
      expect(b.reload.state).to eq("online")
    end

    it "disponibilidade do aparelho muda a situação" do
      publish_devices(z2m_device(ieee: "0x3", name: "porta"))
      broker.deliver("zigbee2mqtt/porta/availability", { state: "offline" })
      expect(site.devices.find_by!(external_id: "0x3").status).to eq("offline")
      broker.deliver("zigbee2mqtt/porta/availability", "lixo")
      expect(site.devices.find_by!(external_id: "0x3").status).to eq("offline")
    end
  end

  describe "pedidos à ponte" do
    it "abre (com roteador), renova e fecha o pareamento; pede o mapa" do
      publish_devices(z2m_device(ieee: "0x4", name: "tomada", type: "Router", power: "Mains (single phase)"))
      expect(bridge.routers(site)).to eq([ %w[tomada tomada] ])
      bridge.open!(site, 999, via: "tomada")
      expect(broker.last("bridge/request/permit_join")).to eq("value" => true, "time" => 254, "device" => "tomada")
      b = bridge.bridge(site)
      expect(b.seconds_left).to be_between(250, 254)
      expect(b.info["via"]).to eq("tomada")

      bridge.open!(site, 60, via: "não existe")
      expect(broker.last("bridge/request/permit_join")).to eq("value" => true, "time" => 60)
      bridge.close!(site)
      expect(broker.last("bridge/request/permit_join")).to eq("value" => false, "time" => 0)
      expect(b.reload.open?).to be false

      bridge.request_map!(site)
      expect(broker.last("bridge/request/networkmap")).to eq("type" => "raw", "routes" => false)
      expect(b.reload.map_pending?).to be true
    end
  end

  describe "renomear de verdade" do
    let!(:device) do
      publish_devices(z2m_device(ieee: "0x5", name: "0x5"))
      site.devices.find_by!(external_id: "0x5")
    end

    it "renomear aqui manda o nome ao z2m e a descoberta não traz o antigo de volta" do
      device.update!(name: "Porta da cozinha")
      expect(broker.last("bridge/request/device/rename")).to eq("from" => "0x5", "to" => "Porta da cozinha", "homeassistant_rename" => true,
                                                                  "transaction" => "ma-rename-#{device.id}")
      expect(device.reload.address["rename_to"]).to eq("Porta da cozinha")

      publish_devices(z2m_device(ieee: "0x5", name: "0x5")) # bridge/devices antes de o z2m aplicar
      expect(device.reload.name).to eq("Porta da cozinha")
      expect(device.address["topic"]).to eq("zigbee2mqtt/0x5")

      sent = broker.published.size
      publish_devices(z2m_device(ieee: "0x5", name: "Porta da cozinha"))
      expect(device.reload.name).to eq("Porta da cozinha")
      expect(device.address).not_to have_key("rename_to")
      expect(device.address["topic"]).to eq("zigbee2mqtt/Porta da cozinha")
      expect(device.points.pluck(Arel.sql("address->>'topic'")).uniq).to eq([ "zigbee2mqtt/Porta da cozinha" ])
      expect(broker.published.size).to eq(sent) # a descoberta não ecoa o nome
    end

    it "nome que o z2m não aceita é recusado aqui" do
      expect(device.update(name: "sala/1")).to be false
      expect(device.errors[:name].join).to include("barra")
      expect(broker.last("bridge/request/device/rename")).to be_nil
    end

    it "z2m recusou: volta ao nome de lá e mostra o erro" do
      device.update!(name: "Duplicado")
      broker.deliver("zigbee2mqtt/bridge/response/device/rename", { data: {}, status: "error", error: "friendly_name em uso", transaction: "ma-rename-#{device.id}" })
      expect(device.reload.name).to eq("0x5")
      expect(device.address).to include("rename_error" => "friendly_name em uso")
      expect(device.address).not_to have_key("rename_to")
      broker.deliver("zigbee2mqtt/bridge/response/device/rename", { data: { from: "a", to: "b" }, status: "ok" })
    end

    it "sem broker na hora fica pendente e vai de novo ao reconectar e na descoberta" do
      allow(Mqtt::Listener).to receive(:publish).and_raise(Drivers::Mqtt::Error, "Sem conexão com o broker MQTT")
      device.update!(name: "Sensor porta")
      expect(device.reload.address["rename_to"]).to eq("Sensor porta")

      allow(Mqtt::Listener).to receive(:publish) { |t, p, **| broker.published << [ t, p ] }
      Mqtt::Z2m.connected(nil)
      expect(broker.last("bridge/request/device/rename")).to include("to" => "Sensor porta")

      broker.published.clear
      publish_devices(z2m_device(ieee: "0x5", name: "0x5")) # mandou há pouco: espera
      expect(broker.last("bridge/request/device/rename")).to be_nil
      travel 2.minutes do
        publish_devices(z2m_device(ieee: "0x5", name: "0x5"))
        expect(broker.last("bridge/request/device/rename")).to include("to" => "Sensor porta")
      end
    end

    it "aparelho de fora da ponte renomeia sem publicar nada" do
      other = create(:device, site: site, name: "Tuya", driver: "tuya_cloud", external_id: "bf1")
      other.update!(name: "Tuya 2")
      expect(broker.published).to be_empty
      expect(Pairing.name_error(other, "a#b")).to be_nil
    end
  end

  describe "sinal (linkquality)" do
    it "grava no aparelho com folga e ignora a ponte" do
      publish_devices(z2m_device(ieee: "0x6", name: "porta"))
      d = site.devices.find_by!(external_id: "0x6")
      broker.deliver("zigbee2mqtt/porta", { contact: true, linkquality: 120 })
      expect(Pairing.mesh(d.reload)).to include("lqi" => 120)
      broker.deliver("zigbee2mqtt/porta", { contact: false, linkquality: 115 })
      expect(Pairing.mesh(d.reload)["lqi"]).to eq(120)
      broker.deliver("zigbee2mqtt/porta", { contact: false, linkquality: 60 })
      expect(Pairing.mesh(d.reload)["lqi"]).to eq(60)
      broker.deliver("zigbee2mqtt/porta", { contact: false, linkquality: "x" })
      Mqtt::Z2m.observe("zigbee2mqtt/bridge/logging", '{"linkquality": 1}')
      expect(Pairing.mesh(d.reload)["lqi"]).to eq(60)
    end
  end

  describe "mapa da rede" do
    let(:raw) do
      { "nodes" => [ { "ieeeAddr" => "0xc", "friendlyName" => "Coordinator", "type" => "Coordinator" },
                     { "ieeeAddr" => "0xr", "friendlyName" => "tomada", "type" => "Router" },
                     { "ieeeAddr" => "0xe", "friendlyName" => "porta", "type" => "EndDevice" },
                     { "ieeeAddr" => "0xf", "friendlyName" => "solto", "type" => "EndDevice", "failed" => [ "lqi" ] } ],
        "links" => [ { "source" => { "ieeeAddr" => "0xr" }, "target" => { "ieeeAddr" => "0xc" }, "lqi" => 200, "relationship" => 2 },
                     { "sourceIeeeAddr" => "0xc", "targetIeeeAddr" => "0xr", "lqi" => 180, "relationship" => 2 },
                     { "sourceIeeeAddr" => "0xe", "targetIeeeAddr" => "0xr", "lqi" => 30, "relationship" => 1 },
                     { "sourceIeeeAddr" => "0xe", "targetIeeeAddr" => "0xz", "lqi" => 99, "relationship" => 1 } ] }
    end

    it "guarda o raw, vira grafo e desenho com pai e sinal" do
      bridge.request_map!(site)
      broker.deliver("zigbee2mqtt/bridge/response/networkmap", { data: { type: "raw", routes: false, value: raw }, status: "ok" })
      b = bridge.bridge(site)
      expect(b.map_pending?).to be false
      expect(b.network_map["nodes"].size).to eq(4)

      layout = Pairing::MapLayout.call(bridge.graph(b))
      nodes = layout[:nodes].index_by { |n| n[:id] }
      expect(nodes["0xc"]).to include(x: 500, y: 500, role: "coordinator")
      expect(nodes["0xe"]).to include(parent: "0xr", lqi: 30)
      expect(nodes["0xf"][:failed]).to be true
      expect(layout[:edges].size).to eq(2)
      expect(layout[:edges].find { |e| e[:a] == "0xc" }).to include(lqi: 200, parent: false)
      expect(Pairing::MapLayout.tone(30)).to eq("weak")
      expect(Pairing::MapLayout.tone(60)).to eq("fair")
      expect(Pairing::MapLayout.tone(200)).to eq("good")
      expect(Pairing::MapLayout.tone(nil)).to eq("muted")

      broker.deliver("zigbee2mqtt/bridge/response/networkmap", { data: {}, status: "error", error: "timeout" })
      expect(b.reload.network_map_error).to eq("timeout")
    end

    it "só aparelhos finais ficam no anel de dentro" do
      layout = Pairing::MapLayout.call(nodes: [ { id: "a", name: "A", role: "end_device" } ], links: [])
      expect(layout[:nodes].first).to include(x: 500.0, y: 250.0, parent: nil)
    end
  end

  describe "sugestão de substituição" do
    let!(:new_device) do
      publish_devices(z2m_device(ieee: "0x7", name: "0x7"))
      site.devices.find_by!(external_id: "0x7").tap { |d| d.points.find_by!(capability: "contact").report!(false) }
    end
    let!(:old_door) do
      create(:device, site: site, name: "Porta Tuya", driver: "tuya_cloud", external_id: "bf1", status: "offline", last_seen_at: 10.minutes.ago, model: "SNZB-04").tap do |d|
        create(:point, device: d, name: "Abertura", capability: "contact", writable: false, address: { "code" => "doorcontact_state" }, value: false)
        create(:point, device: d, name: "Bateria", capability: "measure", unit: "%", device_class: "battery", data_type: "decimal", writable: false, address: { "code" => "battery_percentage" })
      end
    end
    let!(:old_window) do
      create(:device, site: site, name: "Janela Tuya", driver: "tuya_cloud", external_id: "bf2", last_seen_at: 1.minute.ago).tap do |d|
        create(:point, device: d, name: "Abertura", capability: "contact", writable: false, address: { "code" => "doorcontact_state" }, value: true)
      end
    end
    let!(:lamp) { create(:device, site: site, name: "Lâmpada", driver: "tuya_cloud", external_id: "bf3").tap { |d| create(:point, device: d, name: "Luz", capability: "onoff") } }

    it "põe primeiro o que combina em capacidade, bateria, estado e parou há pouco" do
      list = Pairing::Suggest.call(new_device)
      expect(list.map { |i| i.device.name }).to eq([ "Porta Tuya", "Janela Tuya" ])
      best = list.first
      expect(best.reasons.join(" | ")).to include("2 de 2 pontos combinam", "os dois têm bateria", "mesmo estado agora (Abertura)", "parou de responder há", "mesmo modelo")
      expect(best.score).to be > list.last.score
    end

    it "substituir pelo assistente fica com o nome antigo, renomeia no z2m e resolve; desfazer reabre" do
      join = PairingJoin.create!(site: site, protocol: "zigbee2mqtt", external_id: "0x7", device: new_device, status: "successful", joined_at: Time.current)
      pairs = Devices::Replace.suggest(old_door, new_device).select(&:new)
      event = Devices::Replace.call(old_door, new_device, pairs, user: nil, take_name: true)
      expect(new_device.reload.name).to eq("Porta Tuya")
      expect(broker.last("bridge/request/device/rename")).to include("to" => "Porta Tuya")
      expect(join.reload).to have_attributes(resolution: "replaced")
      expect(join.details["replaced_device_name"]).to eq("Porta Tuya")

      Devices::Replace.undo!(event, user: nil)
      expect(join.reload.resolution).to be_nil
    end
  end

  describe "saúde da rede" do
    it "linhas, resumo e ordem" do
      publish_devices(z2m_device(ieee: "0x8", name: "porta"), z2m_device(ieee: "0x9", name: "tomada", type: "Router", power: "Mains (single phase)", exposes: []))
      porta = site.devices.find_by!(external_id: "0x8")
      Point.find(porta.battery_point_id).report!(12)
      porta.update_columns(address: porta.address.merge("mesh" => porta.address["mesh"].merge("lqi" => 20, "lqi_at" => Time.current.iso8601)), status: "offline")
      rows = Pairing::Network.rows(site, bridge)
      expect(rows.map { |r| r.device.name }).to eq([ "porta" ]) # sem exposes não vira aparelho
      r = rows.first
      expect(r).to have_attributes(role: "end_device", power: "battery", lqi: 20, battery: 12, weak?: true, low_battery?: true, problem?: true, stale?: true, id: porta.id)
      expect(Pairing::Network.summary(rows)).to eq(total: 1, routers: 0, ends: 1, weak: 1, low_battery: 1, offline: 1)
      expect(Pairing::Network.sort(rows, "lqi", "desc")).to eq(rows)
    end
  end
end
