require "rails_helper"

# app3: o que o app 0.3.0 precisa da API além do que a web já expõe:
# alertas de detecção (lista com quadro, de qualquer plugin de câmera) e o
# tema que vale agora em cada visão do painel. Plugins falsos por stub_const.
RSpec.describe "API do app 0.3.0 (app3)" do
  let(:user) { create(:user, name: "Teste Ana") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Teste Casa") } }

  describe "GET /sites/:id/detections" do
    let(:fake) do
      Class.new(Integrations::Plugin) do
        describe key: "teste_nvr", title: "Teste NVR", icon: "video-camera", description: "teste", driver: "teste_nvr"
        def self.snapshot(point) = "\xFF\xD8quadro-#{point.value['id']}".b
        def self.event_snapshots? = true
      end
    end
    let(:nvr) { within(tenant) { create(:device, site: site, name: "Teste Garagem", driver: "virtual") } }
    let(:cam) { within(tenant) { create(:device, site: site, name: "Teste Quintal", driver: "virtual") } }
    let!(:det) { within(tenant) { create(:point, device: nvr, site: site, name: "Detecção", capability: "detection") } }
    let!(:det2) { within(tenant) { create(:point, device: cam, site: site, name: "Detecção", capability: "detection") } }

    before do
      stub_const("Integrations::TesteNvrPlugin", fake)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[TesteNvrPlugin])
      within(tenant) do
        nvr.update!(driver: "teste_nvr")
        travel_to(30.minutes.ago) { det.report!(Detections.value(label: "car", score: 90.2, zones: %w[entrada], id: "ev-1")) }
        travel_to(20.minutes.ago) { det2.report!(Detections.value(label: "dog", score: 70)) }
        travel_to(10.minutes.ago) { det2.report!(Detections.value(label: "person", score: 88)) }
        travel_to(5.minutes.ago) { det.report!(Detections.value(label: "person", score: 95, id: "ev-2")) }
      end
    end

    it "lista da mais nova, com tipo, texto e quadro por evento só no plugin que guarda" do
      get "/api/v1/sites/#{site.id}/detections", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(data.map { |d| [ d["camera"], d["kind"] ] }).to eq([ [ "Teste Garagem", "person" ], [ "Teste Quintal", "person" ], [ "Teste Quintal", "animal" ], [ "Teste Garagem", "vehicle" ] ])
      expect(data.last).to include("kind_label" => "Veículo", "score" => 90, "zones" => [ "entrada" ], "text" => "Veículo · entrada · 90%",
                                   "snapshot_path" => "/points/#{det.id}/snapshot?event=ev-1")
      expect(data[1]["snapshot_path"]).to eq("/points/#{det2.id}/snapshot") # a de agora do plugin sem eventos
      expect(data[2]).not_to have_key("snapshot_path") # antiga, sem quadro guardado
      expect(json["meta"]["kinds"].pluck("key")).to include("person", "vehicle")

      get "/api/v1/points/#{det.id}/snapshot?event=ev-1", headers: auth_headers(user)
      expect(response.body.b).to eq("\xFF\xD8quadro-ev-1".b)
      get "/api/v1/points/#{det.id}/snapshot?event=../../x", headers: auth_headers(user)
      expect(response.body.b).to eq("\xFF\xD8quadro-ev-2".b) # id estranho é ignorado
      expect(det.reload.value["id"]).to eq("ev-2") # nada gravado
    end

    it "filtra por tipo e câmera, pagina pelo cursor e recusa data ruim" do
      get "/api/v1/sites/#{site.id}/detections", headers: auth_headers(user), params: { kind: "person" }
      expect(data.size).to eq(2)
      get "/api/v1/sites/#{site.id}/detections", headers: auth_headers(user), params: { point_id: det2.id }
      expect(data.pluck("kind")).to eq(%w[person animal])
      get "/api/v1/sites/#{site.id}/detections", headers: auth_headers(user), params: { limit: 3 }
      expect(data.size).to eq(3)
      get "/api/v1/sites/#{site.id}/detections", headers: auth_headers(user), params: { before: json["meta"]["next_before"] }
      expect(data.pluck("kind")).to eq(%w[vehicle])
      expect(json["meta"]["next_before"]).to be_nil
      get "/api/v1/sites/#{site.id}/detections", headers: auth_headers(user), params: { before: "ontem" }
      expect(response).to have_http_status(:bad_request)
    end

    it "outro tenant não vê" do
      other = create(:user)
      get "/api/v1/sites/#{site.id}/detections", headers: auth_headers(other)
      expect(response.status).to be_in([ 403, 404 ])
    end
  end

  it "Diário pela API sem limit usa a página padrão (não 1 item)" do
    lamp = within(tenant) { create(:point, device: create(:device, site: site, name: "Teste Luz"), site: site, name: "Luz", capability: "onoff", writable: true) }
    within(tenant) { [ 30, 20, 10 ].each { |m| travel_to(m.minutes.ago) { lamp.report!(m == 20) } } }
    get "/api/v1/sites/#{site.id}/logbook", headers: auth_headers(user)
    expect(data.size).to be >= 3
    expect(json["meta"]["next_before"]).to be_nil
    get "/api/v1/sites/#{site.id}/logbook", headers: auth_headers(user), params: { limit: 2 }
    expect(data.size).to eq(2)
  end

  describe "tema de agora no painel" do
    let(:dashboard) { within(tenant) { Dashboard.ensure_for(site).first } }

    it "sai resolvido por visão (noite no fuso do local) e aceita tema novo por stub_const" do
      fake = Class.new(Dashboards::Themes::Base) { describe key: "teste-mar", label: "Teste Mar", accent: "#123456", accent2: "#abcdef", glass: true }
      stub_const("Dashboards::Themes::TesteMar", fake)
      stub_const("Dashboards::Themes::PLUGINS", Dashboards::Themes::PLUGINS + %w[TesteMar])
      within(tenant) do
        d = dashboard.published.deep_dup
        d["theme"] = { "key" => "teste-mar", "night" => "grafite", "blur" => 8 }
        dashboard.publish!(d)
      end
      zone = ActiveSupport::TimeZone[site.timezone]
      travel_to(zone.parse("2026-11-02 12:00")) do
        get "/api/v1/dashboards/#{dashboard.id}", headers: auth_headers(user)
        expect(data["theme"]).to include("key" => "teste-mar")
        expect(data["views"].first["theme_now"]).to eq("key" => "teste-mar", "label" => "Teste Mar", "accent" => "#123456", "accent2" => "#abcdef",
                                                        "glass" => true, "night" => false, "blur" => 8, "is_night" => false)
      end
      travel_to(zone.parse("2026-11-02 22:00")) do
        get "/api/v1/dashboards/#{dashboard.id}", headers: auth_headers(user)
        expect(data["views"].first["theme_now"]).to include("key" => "grafite", "night" => true)
      end
    end

    it "sem tema não manda nada" do
      get "/api/v1/dashboards/#{dashboard.id}", headers: auth_headers(user)
      expect(data["views"].first).not_to have_key("theme_now")
    end
  end
end
