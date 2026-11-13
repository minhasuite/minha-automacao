require "rails_helper"

# Busca global na web (/busca, /busca/abrir, paleta) e no app (GET /api/v1/search,
# POST /api/v1/search/recent) e o painel com só a visão aberta (web e ?lazy=1 da API).
RSpec.describe "Busca rápida e painel sob demanda (web e API)" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:area) { within(tenant) { create(:area, site: site, name: "Varanda") } }
  let!(:device) { within(tenant) { create(:device, site: site, area: area, name: "Pendente", driver: "virtual") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Luz", capability: "onoff", value: false, writable: true) } }
  let!(:gate) { within(tenant) { create(:point, device: device, name: "Portão", capability: "onoff", value: false, writable: true, risk: "critical") } }
  let(:definition) do
    { "schema_version" => 1, "views" => [
      { "id" => "inicio", "title" => "Início", "sections" => [ { "id" => "s1", "title" => "S", "widgets" => [ { "id" => "w-luz", "type" => "tile", "bind" => lamp.id } ] } ] },
      { "id" => "varanda", "title" => "Varanda", "path" => "varanda", "sections" => [ { "id" => "s2", "title" => "S", "widgets" => [ { "id" => "w-portao", "type" => "tile", "bind" => gate.id, "label" => "Portão da varanda" } ] } ] } ] }
  end
  let!(:dashboard) { within(tenant) { site.dashboards.create!(name: "Casa", kind: "custom", site_default: true, definition: definition).tap { |d| d.publish!(definition) } } }

  before { allow(Drivers).to receive(:supported?).and_return(true) }

  describe "web" do
    before { post("/entrar", params: { email: user.email, password: "12345678" }) }

    it "resultado passa por /busca/abrir (recente), a paleta mostra os recentes e a busca vazia também" do
      get "/busca", params: { q: "pendent" } # começo de palavra
      expect(response.body).to include("/busca/abrir?k=device%3A#{device.id}")

      get "/busca/abrir", params: { k: "device:#{device.id}" }
      expect(response).to redirect_to("/dispositivos/#{device.id}")
      get "/busca/abrir", params: { k: "device:outro" }
      expect(response).to redirect_to("/busca")

      get "/"
      expect(response.body).to include(I18n.t("search.recent"), "/busca/abrir?k=device%3A#{device.id}")
      get "/busca"
      expect(response.body).to include(I18n.t("search.recent"), "Pendente", I18n.t("search.keys"))
    end

    it "card de painel abre a visão certa com o card em foco; abas resolvem só a visão aberta" do
      get "/"
      expect(response.body).to include("w-luz")
      expect(response.body).not_to include("Portão da varanda")
      get "/", params: { view: "varanda" }
      expect(response.body).to include("Portão da varanda")
      get "/paineis/#{dashboard.id}", params: { view: "varanda" }
      expect(response.body).to include("Portão da varanda")

      get "/busca", params: { q: "portao varanda" }
      expect(response.body).to include("widget%3A#{dashboard.id}%2Fvaranda%2Fw-portao")
      get "/busca/abrir", params: { k: "widget:#{dashboard.id}/varanda/w-portao" }
      expect(response).to redirect_to("/paineis/#{dashboard.id}?view=varanda#w-portao")
    end
  end

  describe "API" do
    let(:headers) { auth_headers(user) }

    it "GET /search agrupa, traz alvo e a ação pela API; sem q, os recentes" do
      get "/api/v1/search", params: { q: "desligar portao" }, headers: headers
      item = data.find { |i| i["kind"] == "point" }
      expect(item).to include("key" => "point:#{gate.id}", "group" => I18n.t("search.kinds.point"), "url" => "/pontos/#{gate.id}",
                              "target" => { "type" => "point", "id" => gate.id, "site_id" => site.id })
      expect(item["action"]).to include("method" => "POST", "path" => "/points/#{gate.id}/commands", "confirm_title" => "Crítico")
      expect(item["action"]["body"]).to include("command" => "off")
      expect(json["meta"]["groups"]).to include({ "kind" => "point", "label" => I18n.t("search.kinds.point") })

      get "/api/v1/search", params: { q: "varanda" }, headers: headers
      card = data.find { |i| i["kind"] == "widget" }
      expect(card["target"]).to include("type" => "dashboard", "id" => dashboard.id, "view" => "varanda", "widget_id" => "w-portao")

      get "/api/v1/search", headers: headers
      expect(data).to eq([])
      post "/api/v1/search/recent", params: { key: "area:#{area.id}" }, headers: headers
      expect(response).to have_http_status(:no_content)
      post "/api/v1/search/recent", params: { key: "area:nada" }, headers: headers
      expect(response).to have_http_status(:not_found)
      get "/api/v1/search", params: { q: "" }, headers: headers
      expect(data.map { _1["key"] }).to eq([ "area:#{area.id}" ])
      expect(data.first["recent"]).to be(true)
    end

    it "GET /dashboards/:id?lazy=1 resolve só uma visão; &view= traz a outra; sem lazy, todas" do
      get "/api/v1/dashboards/#{dashboard.id}", params: { lazy: 1 }, headers: headers
      first, second = data["views"]
      expect(first["lazy"]).to be_nil
      expect(second).to include("lazy" => true, "sections" => [], "title" => "Varanda")
      expect(data["points"].keys).to eq([ lamp.id ])

      get "/api/v1/dashboards/#{dashboard.id}", params: { lazy: 1, view: "varanda" }, headers: headers
      expect(data["views"].first["lazy"]).to be(true)
      expect(data["views"].last["sections"].first["widgets"].first["id"]).to eq("w-portao")

      get "/api/v1/dashboards/#{dashboard.id}", params: { lazy: 1, draft: 1 }, headers: headers
      expect(data["views"].last["lazy"]).to be(true)

      get "/api/v1/dashboards/#{dashboard.id}", headers: headers
      expect(data["views"].none? { _1["lazy"] }).to be(true)
    end
  end
end
