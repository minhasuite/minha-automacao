require "rails_helper"

# "Substituir aparelho" na web, na API e no app (AppScreen): técnico+, outro
# local/instalação não enxerga, prévia, aplicar e desfazer.
RSpec.describe "Substituir aparelho (web, API e app)" do
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }
  let(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:old_device) { within(tenant) { create(:device, site: site, name: "Porta Tuya", driver: "tuya_cloud", external_id: "bf1", address: { "via" => "hub" }) } }
  let!(:door) { within(tenant) { create(:point, device: old_device, name: "Abertura", capability: "contact", writable: false, address: { "code" => "doorcontact_state" }) } }
  let!(:new_device) { within(tenant) { create(:device, site: site, name: "porta_z2m", driver: "mqtt", external_id: "0x01") } }
  let!(:contact) do
    within(tenant) { create(:point, device: new_device, name: "Abertura", capability: "contact", writable: false, address: { "topic" => "zigbee2mqtt/porta", "json_path" => "contact", "payload_on" => false, "payload_off" => true }) }
  end

  around { |ex| within(tenant) { ex.run } }

  def sign_in(u = owner) = post("/entrar", params: { email: u.email, password: "12345678" })

  def member(role)
    create(:user, tenant: tenant, role: "member").tap { |u| SiteMembership.create!(site: site, user: u, role: role) }
  end

  it "web: escolhe, mapeia com sugestão, mostra a prévia, aplica e desfaz" do
    sign_in
    get "/dispositivos/#{old_device.id}"
    expect(response.body).to include("/dispositivos/#{old_device.id}/substituir")

    get "/dispositivos/#{old_device.id}/substituir"
    expect(response.body).to include("porta_z2m")
    get "/dispositivos/#{old_device.id}/substituir", params: { por: new_device.id }
    expect(response.body).to include("map[#{door.id}]", "invert[#{door.id}]")
    expect(response.body).to match(/<option selected="selected" value="#{contact.id}">/)

    post "/dispositivos/#{old_device.id}/substituir", params: { new_device_id: new_device.id, map: { door.id => contact.id }, invert: { door.id => "0" }, retire: "remove", preview: "1" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Prévia da substituição", "será marcado como removido")

    post "/dispositivos/#{old_device.id}/substituir", params: { new_device_id: new_device.id, map: { door.id => contact.id }, invert: { door.id => "0" }, retire: "remove" }
    expect(response).to redirect_to("/dispositivos/#{new_device.id}")
    expect(door.reload.device_id).to eq(new_device.id)
    expect(old_device.reload.removed_at).to be_present

    get "/dispositivos/#{old_device.id}"
    expect(response.body).to include("Aparelho substituído", "/desfazer-substituicao")
    post "/dispositivos/#{old_device.id}/desfazer-substituicao"
    expect(response).to redirect_to("/dispositivos/#{old_device.id}")
    expect(door.reload.device_id).to eq(old_device.id)
    expect(new_device.points.count).to eq(1)
    post "/dispositivos/#{old_device.id}/desfazer-substituicao"
    expect(flash[:alert]).to be_present
  end

  it "web: erro de mapeamento volta à tela com o aviso" do
    sign_in
    post "/dispositivos/#{old_device.id}/substituir", params: { new_device_id: new_device.id, map: { door.id => "" } }
    expect(response).to redirect_to("/dispositivos/#{old_device.id}/substituir?por=#{new_device.id}")
    expect(flash[:alert]).to be_present
  end

  it "só técnico para cima; morador nem vê o botão" do
    resident = member("resident")
    sign_in(resident)
    get "/dispositivos/#{old_device.id}"
    expect(response.body).not_to include("/substituir")
    get "/dispositivos/#{old_device.id}/substituir"
    expect(response).to redirect_to(root_path).or have_http_status(:forbidden)
    post "/dispositivos/#{old_device.id}/substituir", params: { new_device_id: new_device.id, map: { door.id => contact.id } }
    expect(door.reload.device_id).to eq(old_device.id)
    post "/api/v1/devices/#{old_device.id}/replace", params: { new_device_id: new_device.id, map: { door.id => contact.id } }, headers: auth_headers(resident)
    expect(response).to have_http_status(:forbidden)

    tech = member("technician")
    post "/api/v1/devices/#{old_device.id}/replace", params: { new_device_id: new_device.id, pairs: [ { old: door.id, new: contact.id } ] }, headers: auth_headers(tech), as: :json
    expect(response).to have_http_status(:ok)
  end

  it "outra instalação não acha o aparelho (404) nem usa aparelho de outro local" do
    stranger = create(:user)
    get "/api/v1/devices/#{old_device.id}/replace", headers: auth_headers(stranger)
    expect(response).to have_http_status(:not_found)
    other_site = create(:site, name: "Loja")
    far = create(:device, site: other_site, name: "Longe")
    post "/api/v1/devices/#{old_device.id}/replace", params: { new_device_id: far.id, map: { door.id => contact.id } }, headers: auth_headers(owner)
    expect(response).to have_http_status(:not_found)
  end

  it "API: sugestão, prévia, aplicar e desfazer" do
    get "/api/v1/devices/#{old_device.id}/replace", params: { new_device_id: new_device.id }, headers: auth_headers(owner)
    expect(response).to have_http_status(:ok)
    expect(json.dig("data", "candidates").map { |d| d["id"] }).to include(new_device.id)
    expect(json.dig("data", "pairs", 0)).to include("invert" => false)
    expect(json.dig("data", "pairs", 0, "new", "id")).to eq(contact.id)

    body = { new_device_id: new_device.id, pairs: [ { old: door.id, new: contact.id, invert: false } ], retire: "disable" }
    post "/api/v1/devices/#{old_device.id}/replace", params: body.merge(preview: true), headers: auth_headers(owner), as: :json
    expect(json.dig("data", "retire")).to eq("disable")
    expect(door.reload.device_id).to eq(old_device.id)

    post "/api/v1/devices/#{old_device.id}/replace", params: body, headers: auth_headers(owner), as: :json
    expect(json.dig("data", "pairs", 0, "old_point_id")).to eq(door.id)
    expect(old_device.reload.disabled).to be true

    post "/api/v1/devices/#{old_device.id}/replace", params: { new_device_id: new_device.id, map: { SecureRandom.uuid => contact.id } }, headers: auth_headers(owner), as: :json
    expect(response).to have_http_status(:unprocessable_content)

    post "/api/v1/devices/#{old_device.id}/replace/undo", headers: auth_headers(owner)
    expect(response).to have_http_status(:ok)
    expect(door.reload.device_id).to eq(old_device.id)
    post "/api/v1/devices/#{old_device.id}/replace/undo", headers: auth_headers(owner)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "app (AppScreen): a tela de mapeamento chega com os selects e a caixa de inverter" do
    get "/api/v1/screen", params: { path: "/dispositivos/#{old_device.id}/substituir?por=#{new_device.id}" }, headers: auth_headers(owner)
    expect(response).to have_http_status(:ok)
    blocks = []
    walk = ->(list) { Array(list).each { |b| blocks << b; walk.(b["c"]) } }
    walk.(json.dig("data", "page", "blocks"))
    fields = blocks.select { |b| b["t"] == "field" }
    expect(fields.find { |f| f["name"] == "map[#{door.id}]" }).to include("kind" => "select", "value" => contact.id)
    expect(fields.find { |f| f["name"] == "invert[#{door.id}]" }).to include("kind" => "checkbox")
    expect(blocks.find { |b| b["t"] == "submit" && b["name"] == "preview" }).to be_present
  end
end
