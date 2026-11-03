require "rails_helper"

# tuya: pareamento pelo app (SDK oficial da Tuya). O app pede a conta do SDK
# do local e manda o aparelho pareado; o provedor é um plugin de integração
# (`pairing_session`/`pair`), então outro provedor entra sem mudar o núcleo.
RSpec.describe "Pareamento pelo app" do
  let(:user) { create(:user, name: "Teste Ana") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Teste Casa") } }
  let(:base) { "/api/v1/sites/#{site.id}/pairings" }
  let(:schema) do
    [ { id: 1, code: "switch_1", mode: "rw", type: "bool", property: { type: "bool" } },
      { id: 19, code: "cur_power", mode: "ro", type: "value", property: '{"type":"value","min":0,"max":50000,"scale":1,"unit":"W"}' } ]
  end
  let(:paired) { { device_id: "teste-dev-1", local_key: "chave-teste", name: "Teste Tomada", area_name: "Teste Sala", ip: "192.168.0.50", version: "3.4", product_name: "Tomada 16A", schema: schema } }

  it "conta do SDK: estável por local, sem gravar senha; só técnico ou dono" do
    post "#{base}/tuya/session", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    first = data
    expect(first).to include("country_code" => "55", "home_name" => "Teste Casa")
    expect(first["uid"]).to start_with("ma")
    expect(first["password"].size).to eq(32)
    post "#{base}/tuya/session", headers: auth_headers(user)
    expect(data).to eq(first)

    other = within(tenant) { create(:site, name: "Teste Praia") }
    post "/api/v1/sites/#{other.id}/pairings/tuya/session", headers: auth_headers(user)
    expect(data["uid"]).not_to eq(first["uid"])

    guest = create(:user, tenant: tenant, role: "member", name: "Teste Visita")
    post "#{base}/tuya/session", headers: auth_headers(guest)
    expect(response.status).to be_in([ 403, 404 ]) # sem papel de técnico no local
  end

  it "aparelho pareado vira aparelho local com pontos e área; parear de novo atualiza" do
    post "#{base}/tuya", headers: auth_headers(user), params: paired, as: :json
    expect(response).to have_http_status(:created)
    expect(data).to include("driver" => "tuya_local", "external_id" => "teste-dev-1", "name" => "Teste Tomada", "model" => "Tomada 16A")
    device = within(tenant) { site.devices.find_by!(external_id: "teste-dev-1") }
    expect(device.credential).to eq("chave-teste")
    expect(device.address).to include("host" => "192.168.0.50", "version" => "3.4")
    caps = within(tenant) do
      expect(device.area.name).to eq("Teste Sala")
      device.points.to_h { |p| [ p.address["code"], p.capability ] }
    end
    expect(caps).to include("switch_1" => "onoff", "cur_power" => "measure")

    post "#{base}/tuya", headers: auth_headers(user), params: paired.merge(local_key: "chave-nova", ip: "177.10.0.9"), as: :json
    expect(response).to have_http_status(:ok)
    device.reload
    expect([ device.credential, device.address["host"], within(tenant) { device.points.count } ]).to eq([ "chave-nova", "192.168.0.50", 2 ])
    expect(within(tenant) { site.devices.where(external_id: "teste-dev-1").count }).to eq(1)
  end

  it "erros: sem chave (no idioma do app), provedor desconhecido e plugin sem pareamento" do
    post "#{base}/tuya", headers: auth_headers(user).merge("Accept-Language" => "en"), params: { device_id: "x" }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(json.dig("error", "message")).to include("paired device")
    post "#{base}/nao_existe/session", headers: auth_headers(user)
    expect(response).to have_http_status(:not_found)
    post "#{base}/weather/session", headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)
    post "#{base}/weather", headers: auth_headers(user), params: { device_id: "x" }, as: :json
    expect(json.dig("error", "message")).to eq("Este tipo não pareia aparelhos pelo app.")
  end

  it "outro provedor entra por registro, sem mudar o núcleo" do
    fake = Class.new(Integrations::Plugin) do
      describe key: "teste_par", title: "Teste Par", icon: "link", description: "teste"
      def self.pairing_session(_site, _user) = { "token" => "teste" }
      def self.pair(site, form) = site.devices.create!(driver: "virtual", name: "Teste #{form[:name]}")
    end
    stub_const("Integrations::TesteParPlugin", fake)
    stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[TesteParPlugin])
    post "#{base}/teste_par/session", headers: auth_headers(user)
    expect(data).to eq("token" => "teste")
    post "#{base}/teste_par", headers: auth_headers(user), params: { name: "Lâmpada" }, as: :json
    expect(response).to have_http_status(:created)
    expect(data["name"]).to eq("Teste Lâmpada")
  end
end
