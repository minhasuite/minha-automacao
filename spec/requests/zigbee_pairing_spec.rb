require "rails_helper"

# Assistente de pareamento Zigbee e rede (web, e no app pelo AppScreen):
# técnico+ pareia e decide, qualquer papel vê a rede. Broker falso.
RSpec.describe "Pareamento Zigbee (web e app)" do
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:broker) { FakeMqttBroker.install(self) }
  let!(:sala) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let!(:new_device) do
    broker.deliver("zigbee2mqtt/bridge/devices", [ z2m("0x1", "0x1"), z2m("0x2", "tomada", type: "Router") ])
    broker.deliver("zigbee2mqtt/bridge/event", { type: "device_joined", data: { ieee_address: "0x1", friendly_name: "0x1" } })
    broker.deliver("zigbee2mqtt/bridge/event", { type: "device_interview", data: { ieee_address: "0x1", status: "successful", supported: true, definition: { model: "SNZB-04", vendor: "SONOFF" } } })
    broker.deliver("zigbee2mqtt/bridge/devices", [ z2m("0x1", "0x1"), z2m("0x2", "tomada", type: "Router") ])
    site.devices.find_by!(external_id: "0x1")
  end
  let(:join) { PairingJoin.find_by!(external_id: "0x1") }
  let!(:old_device) do
    create(:device, site: site, name: "Porta Tuya", driver: "tuya_cloud", external_id: "bf1", status: "offline", last_seen_at: 5.minutes.ago).tap do |d|
      create(:point, device: d, name: "Abertura", capability: "contact", writable: false, address: { "code" => "doorcontact_state" })
    end
  end

  around { |ex| within(tenant) { ex.run } }

  def sign_in(u = owner) = post("/entrar", params: { email: u.email, password: "12345678" })

  def member(role)
    create(:user, tenant: tenant, role: "member").tap { |u| SiteMembership.create!(site: site, user: u, role: role) }
  end

  def z2m(ieee, name, type: "EndDevice")
    { "ieee_address" => ieee, "type" => type, "friendly_name" => name, "power_source" => type == "Router" ? "Mains (single phase)" : "Battery", "interview_completed" => true,
      "definition" => { "model" => "SNZB-04", "vendor" => "SONOFF", "description" => "Contato",
                        "exposes" => [ { "type" => "binary", "name" => "contact", "property" => "contact", "access" => 1, "value_on" => false, "value_off" => true },
                                       { "type" => "binary", "name" => "state", "property" => "state", "access" => 7, "value_on" => "ON", "value_off" => "OFF" } ] } }
  end


  it "lista de dispositivos mostra Parear e Rede; a tela abre, renova e fecha o pareamento" do
    sign_in
    get "/locais/#{site.id}/dispositivos"
    expect(response.body).to include("Parear aparelho Zigbee", "/locais/#{site.id}/parear/zigbee2mqtt", "/locais/#{site.id}/rede/zigbee2mqtt")

    get "/locais/#{site.id}/parear/zigbee2mqtt"
    expect(response.body).to include("Como parear", "Pareamento fechado", "pairing-live", "tomada", "Continuar")

    post "/locais/#{site.id}/parear/zigbee2mqtt/abrir", params: { via: "tomada" }
    expect(response).to redirect_to("/locais/#{site.id}/parear/zigbee2mqtt")
    expect(broker.last("bridge/request/permit_join")).to eq("value" => true, "time" => 254, "device" => "tomada")
    follow_redirect!
    expect(response.body).to include("Pareamento aberto", "Fecha em 4:1", "por tomada", "Renovar pareamento")

    get "/locais/#{site.id}/parear/zigbee2mqtt/ao-vivo"
    expect(response.body).to include('<turbo-frame id="pairing-live"', "Pareamento aberto", "0x1", "SONOFF")
    expect(response.body).not_to include("<html")

    post "/locais/#{site.id}/parear/zigbee2mqtt/fechar"
    expect(broker.last("bridge/request/permit_join")).to eq("value" => false, "time" => 0)
  end

  it "sem broker na hora mostra o erro" do
    sign_in
    allow(Mqtt::Listener).to receive(:publish).and_raise(Drivers::Mqtt::Error, "Sem conexão com o broker MQTT")
    post "/locais/#{site.id}/parear/zigbee2mqtt/abrir"
    expect(flash[:alert]).to include("Sem conexão")
    post "/locais/#{site.id}/parear/zigbee2mqtt/fechar"
    expect(flash[:alert]).to include("Sem conexão")
    post "/locais/#{site.id}/rede/zigbee2mqtt/mapa"
    expect(flash[:alert]).to include("Sem conexão")
  end

  it "é novo: nome e área; o nome vai ao z2m e o aparelho sai da fila de decisão" do
    sign_in
    get "/locais/#{site.id}/parear/zigbee2mqtt/aparelho/#{join.id}"
    expect(response.body).to include("É um aparelho novo", "Substitui um aparelho existente", "Porta Tuya", "Mais provável", "parou de responder há")
    expect(response.body).to include("/dispositivos/#{old_device.id}/substituir?assistente=zigbee2mqtt&amp;por=#{new_device.id}")

    post "/locais/#{site.id}/parear/zigbee2mqtt/aparelho/#{join.id}/novo", params: { name: "sala/2", area_id: sala.id }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("barra")

    post "/locais/#{site.id}/parear/zigbee2mqtt/aparelho/#{join.id}/novo", params: { name: "Porta da sala", area_id: sala.id }
    expect(response).to redirect_to("/locais/#{site.id}/parear/zigbee2mqtt")
    expect(new_device.reload).to have_attributes(name: "Porta da sala", area: sala)
    expect(broker.last("bridge/request/device/rename")).to include("from" => "0x1", "to" => "Porta da sala")
    expect(join.reload.resolution).to eq("new")
    follow_redirect!
    expect(response.body).to include("Novo")
    get "/locais/#{site.id}/parear/zigbee2mqtt/aparelho/#{join.id}"
    expect(response.body).to include("Abrir o aparelho")

    get "/dispositivos/#{new_device.id}"
    expect(response.body).to include("Renomeando para", "Aparelho final", "Rede Zigbee")
  end

  it "substitui: pela tela do Substituir, com o nome antigo e de volta ao assistente" do
    sign_in
    get "/dispositivos/#{old_device.id}/substituir", params: { por: new_device.id, assistente: "zigbee2mqtt" }
    expect(response.body).to include('name="assistente"', "fica com o nome")
    door = old_device.points.first
    contact = new_device.points.find_by!(capability: "contact")
    post "/dispositivos/#{old_device.id}/substituir", params: { new_device_id: new_device.id, map: { door.id => contact.id }, retire: "remove", take_name: "1", assistente: "zigbee2mqtt", preview: "1" }
    expect(response.body).to include("passa a se chamar Porta Tuya", 'name="assistente"')
    post "/dispositivos/#{old_device.id}/substituir", params: { new_device_id: new_device.id, map: { door.id => contact.id }, retire: "remove", take_name: "1", assistente: "zigbee2mqtt" }
    expect(response).to redirect_to("/locais/#{site.id}/parear/zigbee2mqtt")
    expect(new_device.reload.name).to eq("Porta Tuya")
    expect(join.reload.resolution).to eq("replaced")
    follow_redirect!
    expect(response.body).to include("Substituiu Porta Tuya")
  end

  it "ignorar e entrevista em andamento" do
    sign_in
    broker.deliver("zigbee2mqtt/bridge/event", { type: "device_joined", data: { ieee_address: "0x9", friendly_name: "0x9" } })
    waiting = PairingJoin.find_by!(external_id: "0x9")
    get "/locais/#{site.id}/parear/zigbee2mqtt/aparelho/#{waiting.id}"
    expect(response.body).to include("Esperando a entrevista", "ss-reload")
    post "/locais/#{site.id}/parear/zigbee2mqtt/aparelho/#{waiting.id}/novo", params: { name: "x" }
    expect(flash[:alert]).to include("entrevista")
    broker.deliver("zigbee2mqtt/bridge/event", { type: "device_interview", data: { ieee_address: "0x9", status: "failed" } })
    get "/locais/#{site.id}/parear/zigbee2mqtt"
    expect(response.body).to include("Resete de novo perto de um roteador")
    post "/locais/#{site.id}/parear/zigbee2mqtt/aparelho/#{join.id}/dispensar"
    expect(join.reload.resolution).to eq("dismissed")
  end

  it "rede: tabela com sinal e bateria, mapa em SVG e pedido do mapa" do
    broker.deliver("zigbee2mqtt/0x1", { contact: true, linkquality: 33 })
    raw = { nodes: [ { ieeeAddr: "0xc", friendlyName: "Coordinator", type: "Coordinator" }, { ieeeAddr: "0x2", friendlyName: "tomada", type: "Router" },
                     { ieeeAddr: "0x1", friendlyName: "0x1", type: "EndDevice" } ],
            links: [ { sourceIeeeAddr: "0x2", targetIeeeAddr: "0xc", lqi: 180, relationship: 2 }, { sourceIeeeAddr: "0x1", targetIeeeAddr: "0x2", lqi: 33, relationship: 1 } ] }
    sign_in
    post "/locais/#{site.id}/rede/zigbee2mqtt/mapa"
    expect(broker.last("bridge/request/networkmap")).to eq("type" => "raw", "routes" => false)
    follow_redirect!
    expect(response.body).to include("Esperando o mapa da ponte")

    broker.deliver("zigbee2mqtt/bridge/response/networkmap", { data: { type: "raw", value: raw }, status: "ok" })
    get "/locais/#{site.id}/rede/zigbee2mqtt", params: { sort: "lqi", dir: "desc" }
    body = response.body
    expect(body).to include("Rede Zigbee", "<svg", "<circle", "Coordenador", "Aparelho final", "Bom (100+)", "tomada")
    expect(body).to include(">33<") # sinal na tabela
    expect(body.scan("/dispositivos/#{new_device.id}").size).to be >= 2 # nó e linha
  end

  it "papéis: morador vê a rede mas não pareia; sem papel = 404" do
    sign_in(member("resident"))
    get "/locais/#{site.id}/rede/zigbee2mqtt"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("/rede/zigbee2mqtt/mapa", "/parear/zigbee2mqtt\"")
    get "/locais/#{site.id}/parear/zigbee2mqtt"
    expect(response).not_to have_http_status(:ok)
    post "/locais/#{site.id}/parear/zigbee2mqtt/abrir"
    expect(broker.published).to be_empty

    sign_in(owner)
    get "/locais/#{site.id}/parear/nada"
    expect(response).to have_http_status(:not_found)
  end

  it "app (AppScreen): o assistente e a rede chegam como blocos, com o recarregar" do
    get "/api/v1/screen", params: { path: "/locais/#{site.id}/parear/zigbee2mqtt" }, headers: auth_headers(owner)
    page = response.parsed_body.dig("data", "page")
    expect(page["title"]).to eq("Parear aparelho Zigbee")
    flat = page["blocks"].to_json
    expect(flat).to include('"t":"reload"', "Abrir pareamento", "Continuar")

    get "/api/v1/screen", params: { path: "/locais/#{site.id}/parear/zigbee2mqtt/aparelho/#{join.id}" }, headers: auth_headers(owner)
    flat = response.parsed_body.dig("data", "page", "blocks").to_json
    expect(flat).to include("Salvar como novo", "Substituir este")

    get "/api/v1/screen", params: { path: "/locais/#{site.id}/rede/zigbee2mqtt" }, headers: auth_headers(owner)
    expect(response.parsed_body.dig("data", "page", "title")).to eq("Rede Zigbee")
  end
end
