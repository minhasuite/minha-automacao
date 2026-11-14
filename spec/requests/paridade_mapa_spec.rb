require "rails_helper"

# Mapa (paridade com o HA): pessoas e zonas dos helpers, trajeto do dia pelo
# app do celular, widget `map` por registro e privacidade por papel.
RSpec.describe "Mapa" do
  let(:user) { create(:user, name: "Teste Ana") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa Teste", latitude: -15.8, longitude: -47.9) } }
  let(:guest) { create(:user, tenant: tenant, role: "member", name: "Teste Visita") }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  def setup_person!
    within(tenant) do
      phone = Integrations::MobileAppPlugin.register!(site, user, install_id: "teste12345", name: "Celular Teste")
      travel_to(Time.current.change(hour: 9)) { Integrations::MobileAppPlugin.report!(phone, "location" => { "latitude" => -15.8, "longitude" => -47.9 }) }
      travel_to(Time.current.change(hour: 10)) { Integrations::MobileAppPlugin.report!(phone, "location" => { "latitude" => -15.7, "longitude" => -47.8 }) }
      Integrations::MobileAppPlugin.report!(phone, "location" => { "latitude" => -15.70001, "longitude" => -47.8 }) # andou menos de 30 m: não soma
      gps = phone.points.find_by!(device_class: "location")
      person = HelperTypes.build(site, HelperTypes::Person)
      HelperTypes.save(person, "name" => "Teste Ana", "user_id" => user.id, "sources" => [ gps.id ])
      zone = HelperTypes.build(site, HelperTypes::Zone)
      HelperTypes.save(zone, "name" => "Teste Trabalho", "latitude" => "-15,7", "longitude" => "-47,8", "radius_m" => "300")
      gps
    end
  end

  it "trajeto do dia só com a coordenada exata e some com ela" do
    gps = setup_person!
    expect(gps.reload.attrs["track"].size).to eq(2)
    data = within(tenant) { Maps.data(site) }
    ana = data["people"].first
    expect(ana).to include("name" => "Teste Ana", "precise" => true, "lat" => -15.70001, "lon" => -47.8)
    expect(ana["track"].map { |t| t.first(2) }).to eq([ [ -15.8, -47.9 ], [ -15.7, -47.8 ] ])
    expect(data["zones"].pluck("name")).to contain_exactly("Casa", "Teste Trabalho")
    expect(data["center"]).to eq([ -15.8, -47.9 ])

    within(tenant) do
      gps.update_column(:reported_at, 2.days.ago) # rubocop:disable Rails/SkipsModelValidations
      Integrations::MobileAppPlugin.forget_old_locations!(site.integrations.find_by!(driver: "mobile_app"))
    end
    expect(gps.reload.attrs.keys).not_to include("latitude", "track")
    ana = within(tenant) { Maps.data(site) }["people"].first
    expect(ana).to include("precise" => false, "track" => []) # fica no centro da zona em que está
  end

  it "página do mapa com Leaflet por importmap; visitante não vê" do
    setup_person!
    sign_in
    get "/mapa"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("data-controller=\"map\"", "Teste Ana", "Teste Trabalho", "Localização do celular", "2 pontos hoje",
                                     "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet-src.esm.js", ">Mapa<")

    within(tenant) { SiteMembership.create!(site: site, user: guest, role: "guest") }
    sign_in(guest)
    get "/diario"
    expect(response.body).not_to include(">Mapa<")
    get "/mapa"
    expect(response).to redirect_to("/")
    expect(flash[:alert]).to include("não mostra onde as pessoas estão")
  end

  it "API do mapa: morador vê, visitante e chave de integração não" do
    setup_person!
    get "/api/v1/sites/#{site.id}/map", headers: auth_headers(user)
    expect(data["people"].first).to include("name" => "Teste Ana", "precise" => true)
    get "/api/v1/sites/#{site.id}/map", headers: auth_headers(user), params: { track: "false" }
    expect(data["people"].first["track"]).to eq([])

    within(tenant) { SiteMembership.create!(site: site, user: guest, role: "operator") }
    get "/api/v1/sites/#{site.id}/map", headers: auth_headers(guest)
    expect(response).to have_http_status(:forbidden)
  end

  it "widget map por registro: mostra para o morador e esconde do visitante, sem coordenada no JSON" do
    setup_person!
    dash = within(tenant) do
      site.dashboards.create!(name: "Teste mapa", definition: { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "Início", "sections" => [
                                { "id" => "s", "widgets" => [ { "id" => "m1", "type" => "map", "height" => 260 } ] }
                              ] } ] })
    end
    expect(Dashboards::Schema.errors(dash.definition)).to eq([])
    expect(Dashboards::Schema.errors({ "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => [ { "id" => "m", "type" => "map", "height" => 5 } ] } ] } ] }).join)
      .to include("height precisa ser de 180 a 800")
    owner = within(tenant) { Dashboards::Resolver.new(dash, role: "owner").call }
    w = owner["views"][0]["sections"][0]["widgets"][0]
    expect(w["data"]["people"].first["lat"]).to eq(-15.70001)
    hidden = within(tenant) { Dashboards::Resolver.new(dash, role: "operator").call }
    expect(hidden["views"][0]["sections"][0]["widgets"][0]["data"]).to eq({ "hidden" => true })

    sign_in
    get "/paineis/#{dash.id}"
    expect(response.body).to include(%(data-map-target="canvas"), "Abrir o mapa", "--mp-h: 260px")
  end
end
