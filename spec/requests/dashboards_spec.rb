require "rails_helper"

RSpec.describe "Dashboards: web e API" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:area) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let!(:device) { within(tenant) { create(:device, site: site, area: area, name: "Lâmpada Sala") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Luz", value: false) } }
  let!(:dimmer) { within(tenant) { create(:point, device: device, name: "Brilho", capability: "dimmer", value: 40) } }
  let!(:power) { within(tenant) { create(:point, device: device, name: "Potência", capability: "measure", unit: "W", device_class: "power", value: 9) } }
  let!(:gate) { within(tenant) { create(:point, device: device, name: "Portão", risk: "critical", value: false) } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })
  def member(role) = create(:user, tenant: tenant, role: "member").tap { |u| within(tenant) { create(:site_membership, site: site, user: u, role: role) } }
  def dashboard = within(tenant) { Dashboard.ensure_for(site).first }

  describe "web" do
    before { sign_in }

    it "o Início mostra o painel automático do local, com widgets e tempo real" do
      within(tenant) { Reading.insert_all!([ { point_id: power.id, at: 1.hour.ago, value: 8 } ]) }
      get "/"
      expect(response.body).to include("Luzes", "Ligados agora", "Consumo", "Segurança", "Portão", "Potência nas últimas 24 h", "data-points", "turbo-cable-stream-source")
      expect(response.body).to include("Luz", "Tudo desligado.")
      view = "a-#{area.id}"
      get "/", params: { view: view }
      expect(response.body).to include("Ajustar Brilho")
      get "/locais/#{site.id}/paineis"
      expect(response.body).to include("Padrão do local")
    end

    it "liga pelo widget (comando com papel) e volta para o quadro do widget" do
      d = dashboard
      wid = "wh-#{lamp.id}"
      post "/pontos/#{lamp.id}/comando", params: { command: "toggle", dashboard_id: d.id, widget_id: wid }, headers: { "Turbo-Frame" => "w_#{wid}" }
      expect(response).to redirect_to("/paineis/#{d.id}/w/#{wid}")
      expect(within(tenant) { lamp.reload.value }).to be true
      get "/paineis/#{d.id}/w/#{wid}"
      expect(response.body).to include(%(id="w_#{wid}"), "Desligar Luz")
      get "/paineis/#{d.id}/w/b-on", params: { badge: 1 }
      expect(response.body).to include("dw-badge", "ligado")
      get "/paineis/#{d.id}/w/nada"
      expect(response).to have_http_status(:not_found)

      within(tenant) { device.update!(disabled: true) }
      post "/pontos/#{lamp.id}/comando", params: { command: "toggle", dashboard_id: d.id, widget_id: wid }, headers: { "Turbo-Frame" => "w_#{wid}" }
      follow_redirect!
      expect(response.body).to include("Ponto desativado").or include("Luz")
    end

    it "edita o rascunho sem JSON, pré-visualiza, publica e volta versão" do
      d = dashboard
      get "/paineis/#{d.id}/editar"
      expect(response.body).to include("Adicionar widget", "Nova visão", "Versões")

      patch "/paineis/#{d.id}/rascunho", params: { op: "add_view", title: "Cozinha" }
      d.reload
      v = d.draft["views"].last["id"]
      expect(response).to redirect_to("/paineis/#{d.id}/editar?view=#{v}")
      patch "/paineis/#{d.id}/rascunho", params: { op: "add_section", view_id: v, title: "Luzes" }
      s = d.reload.draft["views"].last["sections"].first["id"]
      patch "/paineis/#{d.id}/rascunho", params: { op: "add_widget", target: s, view_id: v, widget: { type: "tile", bind: dimmer.id, roles: [ "", "owner", "resident" ] }, span: { mobile: "6", tablet: "6", desktop: "3" } }
      w = d.reload.draft["views"].last["sections"].first["widgets"].first
      expect(w).to include("type" => "tile", "bind" => dimmer.id, "features" => [ "slider" ], "span" => { "mobile" => 6, "tablet" => 6, "desktop" => 3 }, "visible_if" => { "role" => %w[owner resident] })
      {
        "gauge" => { bind: power.id, min: "0", max: "1500,5" }, "stat" => { query: { capability: "onoff", state: "on" }, aggregate: "count" },
        "query_list" => { query: { device_class: "power" }, empty_text: "Nada" }, "chart" => { binds: [ "", power.id ], range: "7d" },
        "group" => { binds: [ lamp.id, gate.id ] }, "area_card" => { area: area.id }, "scene_bar" => {}, "alerts" => {},
        "heading" => { title: "Oi" }, "markdown" => { text: "Bem-vindo" }
      }.each do |type, extra|
        patch "/paineis/#{d.id}/rascunho", params: { op: "add_widget", target: s, view_id: v, widget: { type: type, **extra } }
        expect(flash[:alert]).to be_nil, "#{type}: #{flash[:alert]}"
      end
      widgets = d.reload.draft["views"].last["sections"].first["widgets"]
      expect(widgets.map { |x| x["type"] }).to eq(%w[tile gauge stat query_list chart group area_card scene_bar alerts heading markdown])
      expect(widgets[1]).to include("min" => 0, "max" => 1500.5)
      patch "/paineis/#{d.id}/rascunho", params: { op: "update_widget", target: w["id"], view_id: v, widget: { type: "tile", bind: lamp.id, label: "Teto", color: "amber", tap: "toggle" } }
      expect(d.reload.draft["views"].last["sections"].first["widgets"].first).to include("label" => "Teto", "color" => "amber")
      patch "/paineis/#{d.id}/rascunho", params: { op: "add_widget", target: s, view_id: v, widget: { type: "tile" } }
      expect(flash[:alert]).to include("bind obrigatório")
      patch "/paineis/#{d.id}/rascunho", params: { op: "move", kind: "widget", target: w["id"], dir: "down", view_id: v }
      patch "/paineis/#{d.id}/rascunho", params: { op: "update_section", target: s, title: "Luzes da cozinha", span: { mobile: "12", tablet: "6", desktop: "6" }, view_id: v }
      patch "/paineis/#{d.id}/rascunho", params: { op: "update_view", target: v, title: "Cozinha nova", icon: "home" }
      patch "/paineis/#{d.id}/rascunho", params: { op: "remove", kind: "widget", target: widgets.last["id"], view_id: v }
      patch "/paineis/#{d.id}/rascunho", params: { op: "remove", kind: "widget", target: "nada", view_id: v }
      expect(flash[:alert]).to include("não existe")
      patch "/paineis/#{d.id}/rascunho", params: { op: "explodir" }
      expect(flash[:alert]).to include("não existe")

      get "/paineis/#{d.id}", params: { rascunho: 1, view: v }
      expect(response.body).to include("Pré-visualização do rascunho", "Luzes da cozinha", "Teto", "Oi")
      expect(response.body).not_to include("Bem-vindo")
      get "/paineis/#{d.id}/editar", params: { view: v, w: w["id"] }
      expect(response.body).to include("Cozinha nova", "Salvar widget")

      post "/paineis/#{d.id}/publicar"
      expect(d.reload).to have_attributes(version: 1, auto: false, draft: nil)
      get "/paineis/#{d.id}", params: { view: v }
      expect(response.body).to include("Teto", "Oi")

      patch "/paineis/#{d.id}/rascunho", params: { op: "remove", kind: "view", target: v, view_id: v }
      post "/paineis/#{d.id}/descartar"
      expect(d.reload.draft).to be_nil
      patch "/paineis/#{d.id}/rascunho", params: { op: "remove", kind: "view", target: v, view_id: v }
      post "/paineis/#{d.id}/publicar"
      post "/paineis/#{d.id}/voltar", params: { version: 1 }
      expect(d.reload.version).to eq(3)
      expect(d.definition["views"].map { |x| x["id"] }).to include(v)
    end

    it "JSON avançado valida antes de salvar no rascunho" do
      d = dashboard
      get "/paineis/#{d.id}/json"
      expect(response.body).to include("schema_version")
      patch "/paineis/#{d.id}/json", params: { definition: "{ quebrado" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("JSON inválido")
      patch "/paineis/#{d.id}/json", params: { definition: { schema_version: 1, views: [] }.to_json }
      expect(response.body).to include("views precisa")
      ok = { schema_version: 1, views: [ { id: "v", title: "Só", sections: [] } ] }.to_json
      patch "/paineis/#{d.id}/json", params: { definition: ok }
      expect(d.reload.draft["views"].first["title"]).to eq("Só")
    end

    it "cria painel, ajusta papéis e padrão, escolhe o do Início e exclui" do
      get "/locais/#{site.id}/paineis/novo"
      expect(response.body).to include("Novo painel")
      post "/locais/#{site.id}/paineis", params: { dashboard: { name: "" } }
      expect(response).to have_http_status(:unprocessable_content)
      post "/locais/#{site.id}/paineis", params: { dashboard: { name: "Cozinha", kind: "custom" }, copy_auto: "0" }
      cozinha = within(tenant) { Dashboard.find_by!(name: "Cozinha") }
      expect(cozinha.version).to eq(1)
      patch "/paineis/#{cozinha.id}", params: { dashboard: { name: "Cozinha", roles: [ "", "resident" ], site_default: "1" } }
      expect(cozinha.reload).to have_attributes(roles: [ "resident" ], site_default: true)
      expect(within(tenant) { Dashboard.where(site_default: true).count }).to eq(1)
      post "/paineis/#{cozinha.id}/padrao"
      expect(user.reload.dashboard_prefs).to include("site" => site.id, site.id => cozinha.id)
      get "/"
      expect(response.body).to include("Esta visão ainda está vazia")
      delete "/paineis/#{cozinha.id}"
      expect(within(tenant) { Dashboard.exists?(cozinha.id) }).to be false
    end

    it "visitante vê, não edita, não vê painel restrito e não aciona portão" do
      d = dashboard
      within(tenant) { d.update!(roles: [ "owner" ]) }
      guest = member("guest")
      sign_in(guest)
      get "/"
      expect(response.body).to include("Esta visão ainda está vazia").or include("Vamos montar")
      within(tenant) { d.update!(roles: []) }
      get "/"
      expect(response.body).to include("Luz")
      expect(response.body).not_to include("Editar painel")
      get "/paineis/#{d.id}/editar"
      expect(flash[:alert]).to include("papel")
      patch "/paineis/#{d.id}/rascunho", params: { op: "add_view", title: "X" }
      expect(within(tenant) { d.reload.draft }).to be_nil
      post "/pontos/#{gate.id}/comando", params: { command: "toggle", dashboard_id: d.id, widget_id: "wh-#{gate.id}" }
      expect(within(tenant) { gate.reload.value }).to be false
      within(tenant) { d.update!(roles: [ "owner" ]) }
      get "/paineis/#{d.id}"
      expect(response).to have_http_status(:not_found)
    end

    it "sem local mostra as boas-vindas (dono que dispensou a primeira configuração)" do
      u = create(:user)
      Onboarding.finish!(u.tenant)
      sign_in(u)
      get "/"
      expect(response.body).to include("Vamos montar a sua casa")
    end
  end

  describe "API" do
    let(:headers) { auth_headers(user) }

    it "lista, resolve com ETag, cria, altera, publica, volta versão e exclui" do
      get "/api/v1/sites/#{site.id}/dashboards", headers: headers
      expect(data.first).to include("auto" => true, "default" => true, "version" => 0)
      id = data.first["id"]

      get "/api/v1/dashboards/#{id}", headers: headers
      expect(data["views"].first["title"]).to eq("Início")
      expect(data["points"][lamp.id]).to include("value" => false, "text" => "Desligado", "can_command" => true)
      etag = response.headers["ETag"]
      get "/api/v1/dashboards/#{id}", headers: headers.merge("If-None-Match" => etag)
      expect(response).to have_http_status(:not_modified)
      within(tenant) { lamp.report!(true) }
      get "/api/v1/dashboards/#{id}", headers: headers.merge("If-None-Match" => etag)
      expect(response).to have_http_status(:ok)

      definition = { schema_version: 1, views: [ { id: "v", title: "App", sections: [ { id: "s", widgets: [ { id: "w", type: "tile", bind: lamp.id } ] } ] } ] }
      post "/api/v1/sites/#{site.id}/dashboards", params: { name: "Do app", definition: definition }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      app_id = data["id"]
      expect(data).to include("version" => 1, "auto" => false)
      post "/api/v1/sites/#{site.id}/dashboards", params: { name: "Ruim", definition: { schema_version: 1, views: [] } }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]["details"]["definition"].join).to include("views")

      definition[:views][0][:title] = "App 2"
      put "/api/v1/dashboards/#{app_id}", params: { definition: definition, publish: false }, headers: headers, as: :json
      expect(data).to include("version" => 1, "has_draft" => true)
      get "/api/v1/dashboards/#{app_id}", params: { draft: 1 }, headers: headers
      expect(data["views"].first["title"]).to eq("App 2")
      post "/api/v1/dashboards/#{app_id}/publish", headers: headers
      expect(data["version"]).to eq(2)
      put "/api/v1/dashboards/#{app_id}", params: { name: "Do app", site_default: true, definition: definition }, headers: headers, as: :json
      expect(data).to include("version" => 3, "site_default" => true)
      post "/api/v1/dashboards/#{app_id}/revert", params: { version: 1 }, headers: headers, as: :json
      expect(data["version"]).to eq(4)
      get "/api/v1/dashboards/#{app_id}/versions", headers: headers
      expect(data.map { |v| v["version"] }).to eq([ 4, 3, 2, 1 ])
      delete "/api/v1/dashboards/#{app_id}", headers: headers
      expect(response).to have_http_status(:no_content)
    end

    it "papel: visitante lê sem rascunho e não altera; painel restrito some" do
      guest = member("guest")
      h = auth_headers(guest)
      id = dashboard.id
      get "/api/v1/dashboards/#{id}", params: { draft: 1 }, headers: h
      expect(data["can_edit"]).to be false
      expect(data["points"][gate.id]["can_command"]).to be false
      put "/api/v1/dashboards/#{id}", params: { name: "X" }, headers: h, as: :json
      expect(response).to have_http_status(:forbidden)
      within(tenant) { Dashboard.find(id).update!(roles: [ "owner" ]) }
      get "/api/v1/sites/#{site.id}/dashboards", headers: h
      expect(data).to eq([])
      get "/api/v1/dashboards/#{id}", headers: h
      expect(response).to have_http_status(:not_found)
      get "/api/v1/dashboards/#{id}", headers: auth_headers(create(:user))
      expect(response).to have_http_status(:not_found)
    end
  end
end
