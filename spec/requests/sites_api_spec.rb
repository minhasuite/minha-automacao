require "rails_helper"

RSpec.describe "API de locais, dispositivos e pontos" do
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }
  let(:headers) { auth_headers(owner) }

  def member(role, **attrs)
    user = create(:user, tenant: tenant, role: "member")
    within(tenant) { create(:site_membership, site: site, user: user, role: role, **attrs) }
    auth_headers(user)
  end

  it "monta local → área → dispositivo virtual → ponto e comanda" do
    post "/api/v1/sites", params: { name: "Casa", kind: "home", latitude: -15.8 }, headers: headers
    expect(response).to have_http_status(:created)
    expect(data).to include("name" => "Casa", "timezone" => "America/Sao_Paulo", "latitude" => -15.8, "my_role" => "owner")
    site_id = data["id"]

    post "/api/v1/sites/#{site_id}/areas", params: { name: "Garagem", kind: "room" }, headers: headers
    area_id = data["id"]
    post "/api/v1/sites/#{site_id}/devices", params: { name: "Relé", area_id: area_id, address: { ip: "10.0.0.2" } }, headers: headers, as: :json
    expect(data).to include("driver" => "virtual", "area_id" => area_id, "address" => { "ip" => "10.0.0.2" })
    device_id = data["id"]

    post "/api/v1/devices/#{device_id}/points", params: { name: "Portão", capability: "onoff", risk: "sensitive", expose: { alexa: true } },
                                                headers: headers, as: :json
    expect(response).to have_http_status(:created)
    expect(data).to include("key" => "rele.portao", "writable" => true, "scale" => 1.0, "value" => nil, "expose" => { "alexa" => true })
    point_id = data["id"]

    post "/api/v1/points/#{point_id}/commands", params: { command: "on", client_uuid: "5b0c1c51-8a4e-4f53-9f0e-2a3d4b5c6d7e" }, headers: headers
    expect(response).to have_http_status(:accepted)
    expect(data).to include("status" => "confirmed", "source" => "api", "point_value" => true, "user_id" => owner.id)
    command_id = data["command_id"]
    post "/api/v1/points/#{point_id}/commands", params: { command: "off", client_uuid: "5b0c1c51-8a4e-4f53-9f0e-2a3d4b5c6d7e" }, headers: headers
    expect(data).to include("command_id" => command_id, "command" => "on")
    get "/api/v1/commands/#{command_id}", headers: headers
    expect(data).to include("status" => "confirmed", "confirmed_at" => be_present)
    get "/api/v1/points/#{point_id}", headers: headers
    expect(data["value"]).to be true

    post "/api/v1/points/#{point_id}/commands", params: { command: "set", value: 3 }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(json.dig("error", "code")).to eq("unsupported_command")
    post "/api/v1/points/#{point_id}/commands", headers: headers
    expect(json.dig("error", "code")).to eq("parameter_missing")

    get "/api/v1/sites", headers: headers
    expect(json["meta"]).to include("count" => 1)
    get "/api/v1/sites/#{site_id}/areas", headers: headers
    expect(data.pluck("name")).to eq([ "Garagem" ])
    get "/api/v1/sites/#{site_id}/devices", params: { area_id: area_id }, headers: headers
    expect(data.size).to eq(1)
    get "/api/v1/devices/#{device_id}/points", headers: headers
    expect(data.pluck("id")).to eq([ point_id ])
    get "/api/v1/sites/#{site_id}", headers: headers
    get "/api/v1/areas/#{area_id}", headers: headers
    get "/api/v1/devices/#{device_id}", headers: headers
    expect(response).to have_http_status(:ok)

    patch "/api/v1/sites/#{site_id}", params: { name: "Casa Nova" }, headers: headers
    patch "/api/v1/areas/#{area_id}", params: { name: "Garagem 2" }, headers: headers
    patch "/api/v1/devices/#{device_id}", params: { name: "Relé 2" }, headers: headers
    patch "/api/v1/points/#{point_id}", params: { name: "Portão social", pulse_ms: 500 }, headers: headers
    expect(data).to include("name" => "Portão social", "pulse_ms" => 500)
    patch "/api/v1/points/#{point_id}", params: { capability: "nada" }, headers: headers
    expect(json.dig("error", "code")).to eq("validation_failed")

    delete "/api/v1/points/#{point_id}", headers: headers
    delete "/api/v1/devices/#{device_id}", headers: headers
    delete "/api/v1/areas/#{area_id}", headers: headers
    expect(response).to have_http_status(:no_content)
    delete "/api/v1/sites/#{site_id}", headers: headers
    expect(within(tenant) { Site.count }).to eq(0)
  end

  it "outra empresa não vê nem comanda (404)" do
    point = within(tenant) { create(:point) }
    stranger = auth_headers(create(:user))
    get "/api/v1/sites/#{point.site_id}", headers: stranger
    expect(response).to have_http_status(:not_found)
    post "/api/v1/points/#{point.id}/commands", params: { command: "on" }, headers: stranger
    expect(response).to have_http_status(:not_found)
    get "/api/v1/sites", headers: stranger
    expect(data).to be_empty
  end

  describe "papéis no local" do
    let(:site) { within(tenant) { create(:site) } }
    let(:device) { within(tenant) { create(:device, site: site) } }
    let!(:lamp) { within(tenant) { create(:point, device: device) } }
    let!(:gate) { within(tenant) { create(:point, device: device, capability: "gate", risk: "sensitive") } }

    it "membro sem papel no local não vê; membro da empresa não cria local" do
      user = create(:user, tenant: tenant, role: "member")
      get "/api/v1/sites/#{site.id}", headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
      post "/api/v1/sites", params: { name: "X" }, headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)
    end

    it "visitante vê e liga a luz, mas não abre o portão nem cadastra; vencido perde o acesso" do
      h = member("guest", expires_at: 1.hour.from_now)
      get "/api/v1/sites", headers: h
      expect(data.first).to include("id" => site.id, "my_role" => "guest")
      post "/api/v1/points/#{lamp.id}/commands", params: { command: "on" }, headers: h
      expect(response).to have_http_status(:accepted)
      post "/api/v1/points/#{gate.id}/commands", params: { command: "pulse" }, headers: h
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/sites/#{site.id}/areas", params: { name: "Sala" }, headers: h
      expect(response).to have_http_status(:forbidden)
      patch "/api/v1/sites/#{site.id}", params: { name: "Minha" }, headers: h
      expect(response).to have_http_status(:forbidden)

      within(tenant) { SiteMembership.find_each { |m| m.update!(expires_at: 1.minute.ago) } }
      get "/api/v1/sites/#{site.id}", headers: h
      expect(response).to have_http_status(:not_found)
    end

    it "operador abre o portão; técnico cadastra mas não mexe no local" do
      post "/api/v1/points/#{gate.id}/commands", params: { command: "pulse" }, headers: member("operator")
      expect(data["point_value"]).to eq("open")
      tech = member("technician")
      post "/api/v1/sites/#{site.id}/areas", params: { name: "Sala" }, headers: tech
      expect(response).to have_http_status(:created)
      delete "/api/v1/sites/#{site.id}", headers: tech
      expect(response).to have_http_status(:forbidden)
      get "/api/v1/sites/#{site.id}/members", headers: tech
      expect(response).to have_http_status(:forbidden)
    end

    it "dono gerencia os membros do local (só gente da empresa)" do
      user = create(:user, tenant: tenant, role: "member")
      post "/api/v1/sites/#{site.id}/members", params: { user_id: user.id, role: "guest", expires_at: 1.day.from_now }, headers: headers
      expect(response).to have_http_status(:created)
      expect(data).to include("role" => "guest", "user" => { "name" => user.name, "email" => user.email })
      id = data["id"]
      get "/api/v1/sites/#{site.id}/members", headers: headers
      expect(data.size).to eq(1)
      patch "/api/v1/members/#{id}", params: { role: "resident" }, headers: headers
      expect(data["role"]).to eq("resident")
      patch "/api/v1/members/#{id}", params: { role: "rei" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      post "/api/v1/sites/#{site.id}/members", params: { user_id: create(:user).id }, headers: headers
      expect(response).to have_http_status(:not_found)
      delete "/api/v1/members/#{id}", headers: headers
      expect(response).to have_http_status(:no_content)
    end
  end
end
