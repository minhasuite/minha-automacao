require "rails_helper"

# mobile-ajustes: painel "Mostrar em" (celular/web) e, por pessoa, os painéis permitidos e o padrão
# (web e app) valendo na API, na web, na busca e no tempo real (quadro do widget).
RSpec.describe "Painéis por superfície e por pessoa" do
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:device) { within(tenant) { create(:device, site: site, name: "Pendente", driver: "virtual") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Luz", capability: "onoff", value: false, writable: true) } }
  let(:definition) do
    { "schema_version" => 1, "views" => [ { "id" => "inicio", "title" => "Início",
                                            "sections" => [ { "id" => "s1", "title" => "S", "widgets" => [ { "id" => "w-luz", "type" => "tile", "bind" => lamp.id, "label" => "Luz da sala" } ] } ] } ] }
  end
  let!(:casa) { make("Casa", site_default: true, position: 1) }
  let!(:mobile) { make("Mobile", position: 2) }
  let!(:ia) { make("IA", position: 3) }
  let!(:ia_mobile) { make("IA Mobile", position: 4) }
  let(:lia) { create(:user, tenant: tenant, role: "member", name: "Lia").tap { |u| within(tenant) { create(:site_membership, site: site, user: u, role: "resident") } } }

  def make(name, **attrs) = within(tenant) { site.dashboards.create!(name: name, kind: "custom", definition: definition, sidebar: true, **attrs).tap { |d| d.publish!(definition) } }
  def sign_in(u) = post("/entrar", params: { email: u.email, password: "12345678" })
  def membership(u) = within(tenant) { SiteMembership.find_by!(user: u, site: site) }
  def api_list(u, **params)
    get "/api/v1/sites/#{site.id}/dashboards", params: params, headers: auth_headers(u)
    response.parsed_body["data"]
  end

  describe "Mostrar em" do
    it "sem marca vale o nome (Mobile/Celular/App ou app_default = celular); marcado vale a marca" do
      within(tenant) do
        expect([ casa, mobile, ia, ia_mobile ].map(&:show_in_effective)).to eq(%w[web app web app])
        expect(casa).to be_show_in_auto
        expect(site.dashboards.new(name: "Painel do celular").show_in_effective).to eq("app")
        ia.update!(app_default: true)
        expect(ia.show_in_effective).to eq("app")
        ia.update!(show_in: "both")
        expect([ ia.shown_in?("web"), ia.shown_in?("app"), ia.show_in_auto? ]).to eq([ true, true, false ])
        expect(ia.update(show_in: "tv")).to be false
        expect(Dashboard.for_surface([ casa, ia ].tap { ia.update!(show_in: "web") }, "app")).to eq([ casa, ia ]) # nenhum do celular = todos
      end
    end

    it "a API (lista do app) traz só os do celular, com show_in; ?all=1 traz todos; o padrão do app é o 1º do celular" do
      list = api_list(owner)
      expect(list.pluck("name")).to eq([ "Mobile", "IA Mobile" ])
      expect(list.first).to include("show_in" => "app", "show_in_auto" => true, "default" => true)
      expect(api_list(owner, all: 1).pluck("name")).to eq([ "Casa", "Mobile", "IA", "IA Mobile" ])

      # A escolha da pessoa no app aparece mesmo sendo da web.
      owner.update!(dashboard_prefs: { "app:#{site.id}" => ia.id })
      list = api_list(owner)
      expect(list.pluck("name")).to eq([ "Mobile", "IA", "IA Mobile" ])
      expect(list.find { |d| d["default"] }["name"]).to eq("IA")

      put "/api/v1/dashboards/#{casa.id}", params: { show_in: "both" }, headers: auth_headers(owner), as: :json
      expect(response.parsed_body.dig("data", "show_in")).to eq("both")
    end

    it "web: editável no editor e na lista de Configurações → Painéis; o menu da web esconde o só do celular" do
      sign_in(owner)
      get "/configuracoes/paineis"
      expect(response.body).to include("Mostrar em", "Automático (Celular)", %(id="show-in-#{mobile.id}"))
      expect(response.body).not_to include(%(href="/paineis/#{mobile.id}" class="ss-shell-link)) # (link do menu, ver abaixo)
      get "/"
      menu = Nokogiri::HTML(response.body).css("nav a").map { |a| a["href"] }
      expect(menu).to include("/paineis/#{ia.id}")
      expect(menu).not_to include("/paineis/#{mobile.id}")

      patch "/paineis/#{mobile.id}/mostrar-em", params: { show_in: "both" }
      expect(response).to redirect_to("/configuracoes/paineis")
      expect(within(tenant) { mobile.reload.show_in }).to eq("both")
      patch "/paineis/#{mobile.id}/mostrar-em", params: { show_in: "" }
      expect(within(tenant) { mobile.reload.show_in }).to be_nil

      get "/paineis/#{ia.id}/editar"
      expect(response.body).to include("dashboard[show_in]")
      patch "/paineis/#{ia.id}", params: { dashboard: { name: "IA", show_in: "app" } }
      expect(within(tenant) { ia.reload.show_in }).to eq("app")
    end

    it "só quem edita muda o Mostrar em" do
      sign_in(lia)
      patch "/paineis/#{mobile.id}/mostrar-em", params: { show_in: "web" }
      expect(within(tenant) { mobile.reload.show_in }).to be_nil
    end
  end

  describe "painéis por pessoa" do
    before { within(tenant) { membership(lia).update!(dashboard_ids: [ casa.id, mobile.id ]) } }

    it "a API lista e abre só os permitidos; o resto é 404 (inclusive o ?all=1)" do
      expect(api_list(lia).pluck("name")).to eq([ "Mobile" ])
      expect(api_list(lia, all: 1).pluck("name")).to eq(%w[Casa Mobile])
      get "/api/v1/dashboards/#{ia_mobile.id}", headers: auth_headers(lia)
      expect(response).to have_http_status(:not_found)
      get "/api/v1/dashboards/#{mobile.id}", headers: auth_headers(lia)
      expect(response).to have_http_status(:ok)
    end

    it "web: painel e quadro do widget (tempo real) não permitidos = 404; o menu e a busca não mostram" do
      sign_in(lia)
      get "/paineis/#{ia.id}"
      expect(response).to have_http_status(:not_found)
      get "/paineis/#{ia.id}/w/w-luz"
      expect(response).to have_http_status(:not_found)
      get "/paineis/#{casa.id}/w/w-luz"
      expect(response).to have_http_status(:ok)
      get "/"
      menu = Nokogiri::HTML(response.body).css("nav a").map { |a| a["href"] }
      expect(menu).not_to include("/paineis/#{ia.id}")

      get "/busca", params: { q: "IA" }
      expect(response.body).not_to include("dashboard%3A#{ia.id}")
      get "/busca", params: { q: "Luz da sala" }
      expect(response.body).to include("widget%3A#{casa.id}")
      expect(response.body).not_to include("widget%3A#{ia.id}")
      get "/api/v1/search", params: { q: "Mobile" }, headers: auth_headers(lia)
      expect(response.body).to include(mobile.id)
      expect(response.body).not_to include(ia_mobile.id)
    end

    it "dono e administradores sempre veem todos" do
      admin = create(:user, tenant: tenant, role: "admin")
      expect(api_list(admin, all: 1).size).to eq(4)
      expect(api_list(owner, all: 1).size).to eq(4)
      sign_in(admin)
      get "/paineis/#{ia.id}"
      expect(response).to have_http_status(:ok)
    end

    it "o padrão que não é permitido cai no primeiro permitido" do
      lia.update!(dashboard_prefs: { site.id => ia.id, "app:#{site.id}" => ia_mobile.id })
      within(tenant) do
        expect(Dashboard.default_for(site, lia.reload, "resident")).to eq(casa)
        expect(Dashboard.default_for(site, lia, "resident", app: true)).to eq(mobile)
      end
    end
  end

  describe "Configurações → Pessoas → pessoa" do
    it "o dono marca os painéis permitidos e o padrão na web e no app" do
      sign_in(owner)
      get "/configuracoes/pessoas/#{lia.id}"
      expect(response.body).to include("Painéis", "Painel padrão no app", %(name="dashboards[#{site.id}][ids][]"))

      patch "/configuracoes/pessoas/#{lia.id}/paineis", params: { dashboards: { site.id => { ids: [ casa.id, mobile.id ], web: casa.id, app: mobile.id } } }
      expect(response).to redirect_to("/configuracoes/pessoas/#{lia.id}")
      expect(membership(lia).dashboard_ids).to contain_exactly(casa.id, mobile.id)
      expect(lia.reload.dashboard_prefs).to include(site.id => casa.id, "app:#{site.id}" => mobile.id)

      # Padrão fora dos permitidos não grava; todos marcados = todos (nil, inclusive os novos).
      patch "/configuracoes/pessoas/#{lia.id}/paineis", params: { dashboards: { site.id => { ids: [ casa, mobile, ia, ia_mobile ].map(&:id), web: "", app: "x" } } }
      expect(membership(lia).dashboard_ids).to be_nil
      expect(lia.reload.dashboard_prefs.keys).not_to include(site.id, "app:#{site.id}")

      patch "/configuracoes/pessoas/#{lia.id}/paineis", params: { dashboards: { site.id => { ids: [] } } }
      expect(flash[:alert]).to include("pelo menos um")
      expect(membership(lia).dashboard_ids).to be_nil
    end

    it "administrador não muda e a pessoa administradora não tem o que marcar" do
      admin = create(:user, tenant: tenant, role: "admin")
      sign_in(admin)
      patch "/configuracoes/pessoas/#{lia.id}/paineis", params: { dashboards: { site.id => { ids: [ casa.id ] } } }
      expect(membership(lia).dashboard_ids).to be_nil
      sign_in(owner)
      get "/configuracoes/pessoas/#{admin.id}"
      expect(response.body).to include("Dono e administradores abrem todos os painéis.")
      patch "/configuracoes/pessoas/#{admin.id}/paineis", params: {}
      expect(flash[:alert]).to be_present
    end

    it "exporta os papéis por local com os painéis permitidos" do
      within(tenant) { membership(lia).update!(dashboard_ids: [ casa.id ]) }
      data = Accounts::ExportData.call(tenant, owner)
      expect(data[:site_memberships].find { |m| m["user_id"] == lia.id }["dashboard_ids"]).to eq([ casa.id ])
    end
  end
end
