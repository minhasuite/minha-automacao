require "rails_helper"

# Telas da arrumação (P2.1 e ideias 3, 6 e 8): regras em Configurações →
# Painéis, "Arrumar esta visão" com prévia, visão automática e congelar,
# montagem por frase (provedor falso), mudanças do rascunho e o assistente.
RSpec.describe "Arrumação dos painéis (telas)" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:cozinha) { within(tenant) { create(:area, site: site, name: "Cozinha") } }
  let!(:sala) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let!(:dev) { within(tenant) { create(:device, site: site, area: cozinha, name: "Cozinha") } }
  let!(:luz) { within(tenant) { create(:point, device: dev, name: "Luz", writable: true, value: false) } }
  let!(:porta) { within(tenant) { create(:point, device: dev, name: "Abertura", capability: "contact", device_class: "door", writable: false, value: false) } }
  let(:room) do
    { "id" => "v-coz", "title" => "Cozinha", "area" => cozinha.id, "sections" => [
      { "id" => "s-1", "widgets" => [ { "id" => "t-porta", "type" => "tile", "bind" => porta.id }, { "id" => "t-luz", "type" => "tile", "bind" => luz.id } ] }
    ] }
  end
  let(:defn) { { "schema_version" => 1, "views" => [ { "id" => "home", "title" => "Início", "sections" => [] }, room ] } }
  let!(:dashboard) { within(tenant) { site.dashboards.create!(name: "Casa", kind: "custom", definition: defn).tap { _1.publish!(defn, author: user) } } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  before { sign_in }

  it "o editor mostra as ferramentas; a prévia mostra antes → depois e aplicar vai para o rascunho" do
    get "/paineis/#{dashboard.id}/editar", params: { view: "v-coz" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Arrumar esta visão", "Montar por frase", "Visão automática da área", "Montar sozinha")

    get "/paineis/#{dashboard.id}/arrumar", params: { view: "v-coz" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Antes", "Depois", "Aplicar ao rascunho", "Abertura")
    post "/paineis/#{dashboard.id}/arrumar", params: { view: "v-coz" }
    expect(response).to redirect_to("/paineis/#{dashboard.id}/editar?view=v-coz")
    draft = dashboard.reload.draft["views"][1]
    expect(draft["badges"].pluck("id")).to eq([ "t-porta" ])
    expect(dashboard.version).to eq(1)

    get "/paineis/#{dashboard.id}/arrumar", params: { view: "v-coz" }
    expect(response.body).to include("já está arrumada")
    get "/paineis/#{dashboard.id}/mudancas"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Publicado", "Rascunho", "Mudou", "Publicar")
    get "/paineis/#{dashboard.id}/arrumar", params: { view: "nada" }
    expect(response).to redirect_to("/paineis/#{dashboard.id}/editar")
  end

  it "visão automática: cria, se refaz, congela" do
    post "/paineis/#{dashboard.id}/visao-automatica", params: { area_id: sala.id }
    view = dashboard.reload.draft["views"].last
    expect(view).to include("title" => "Sala", "auto" => { "area" => sala.id })
    post "/paineis/#{dashboard.id}/visao-automatica", params: { view: "v-coz" }
    expect(dashboard.reload.draft["views"][1]["auto"]).to eq("area" => cozinha.id)
    get "/paineis/#{dashboard.id}/editar", params: { view: "v-coz" }
    expect(response.body).to include("se monta sozinha", "Congelar")
    get "/paineis/#{dashboard.id}/arrumar", params: { view: "v-coz" }
    expect(flash[:alert]).to include("congele")

    post "/paineis/#{dashboard.id}/congelar", params: { view: "v-coz" }
    expect(dashboard.reload.draft["views"][1]).not_to have_key("auto")
    post "/paineis/#{dashboard.id}/congelar", params: { view: "nada" }
    expect(flash[:alert]).to be_present
  end

  it "montagem por frase com a IA da instalação (provedor falso) e o erro sem provedor" do
    post "/paineis/#{dashboard.id}/montar", params: { text: "monte a cozinha", view_id: "home" }
    expect(response).to redirect_to("/paineis/#{dashboard.id}/editar?view=home")
    expect(flash[:alert]).to include("IA")

    answer = { "title" => "Cozinha nova", "sections" => [ { "title" => "Luzes", "widgets" => [ { "type" => "tile", "point" => luz.id }, { "type" => "tile", "point" => "x" } ] } ] }
    klass = Class.new(Ai::Providers::Base) do
      describe key: "eco", label: "Eco", default_model: "eco-1", capabilities: %i[text structured], key_required: false
      define_method(:complete) { |**| Ai::Providers::Base::Result.new(data: answer, usage: { input: 1, output: 1 }) }
    end
    stub_const("Ai::Providers::Eco", klass)
    stub_const("Ai::PROVIDERS", Ai::PROVIDERS + %w[Eco])
    within(tenant) { AiAccount.create!(provider: "eco") }
    post "/paineis/#{dashboard.id}/montar", params: { text: "monte a cozinha" }
    expect(response).to redirect_to(%r{/paineis/#{dashboard.id}/mudancas\?view=ia-})
    expect(flash[:notice]).to include("Ficaram de fora: x")
    follow_redirect!
    expect(response.body).to include("Cozinha nova", "Nova", "Luz")
    expect(dashboard.reload.draft["views"].last["title"]).to eq("Cozinha nova")
  end

  it "regras em Configurações → Painéis: salvar, erro e voltar ao padrão" do
    get "/configuracoes/paineis"
    expect(response.body).to include("Regras de arrumação", "Assistente")
    get "/configuracoes/paineis/arrumacao/#{site.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Selos no topo", "Colunas", "Painel automático", "commandable=false", "tag=iluminacao")
    expect(response.body).not_to include("Voltar ao padrão")

    params = { arrange: { badges: { widgets: "tile", queries: "capability=contact", icons: "door=mdi:door" },
                          columns: { "0" => { id: "tudo", title: "Tudo", queries: "capability=onoff" }, "1" => { id: "" } }, fallback: "tudo" },
               auto: { light: "tag=luz", technical: "", security: "risk=critical", power: "device_class=power", light_names: "0", power_limit: "3" } }
    patch "/configuracoes/paineis/arrumacao/#{site.id}", params: params
    expect(flash[:notice]).to eq("Regras salvas.")
    saved = site.reload.settings["dashboard_defaults"]
    expect(saved["arrange"]["columns"]).to eq([ { "id" => "tudo", "title" => "Tudo", "match" => [ { "query" => { "capability" => "onoff" } } ] } ])
    expect(saved["auto_rules"]).to include("light" => [ { "tag" => "luz" } ], "light_names" => false, "power_limit" => 3)
    get "/configuracoes/paineis/arrumacao/#{site.id}"
    expect(response.body).to include("Voltar ao padrão")

    patch "/configuracoes/paineis/arrumacao/#{site.id}", params: params.deep_merge(arrange: { fallback: "z" })
    expect(flash[:alert]).to include("coluna reserva")
    patch "/configuracoes/paineis/arrumacao/#{site.id}", params: params.deep_merge(auto: { light: "foguete=1" })
    expect(flash[:alert]).to include("filtro desconhecido")
    patch "/configuracoes/paineis/arrumacao/#{site.id}", params: { reset: "1" }
    expect(site.reload.settings["dashboard_defaults"]).to be_nil
  end

  it "assistente em Painéis cria o painel pronto; a primeira configuração usa o mesmo" do
    get "/locais/#{site.id}/paineis"
    expect(response.body).to include("Assistente")
    get "/locais/#{site.id}/paineis/assistente"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Cômodos", "Arrumado em colunas", "Por aparelho", "Cozinha")
    post "/locais/#{site.id}/paineis/assistente", params: { name: "Novo", areas: [ cozinha.id, "" ], layout: "columns", theme: "aurora" }
    board = within(tenant) { site.dashboards.find_by!(name: "Novo") }
    expect(response).to redirect_to("/paineis/#{board.id}")
    expect(board.definition["views"].pluck("title")).to eq([ "Início", "Cozinha" ])

    ctx = Onboarding::Context.new(user: user, site: site, data: {})
    params = ActionController::Parameters.new(theme: "aurora", layout: "columns", areas: [ cozinha.id ])
    within(tenant) do
      auto = site.dashboards.create!(name: "Auto", kind: "home", auto: true, site_default: true)
      site.dashboards.where.not(id: auto.id).update_all(site_default: false)
      expect(Onboarding::Steps::DashboardStep.locals(ctx)[:areas].map(&:name)).to eq(%w[Cozinha Sala])
      expect(Onboarding::Steps::DashboardStep.save(ctx, params)).to be_nil
      expect(auto.reload).not_to be_auto
      expect(auto.definition["views"].last["auto"]).to eq("area" => cozinha.id)
      all = ActionController::Parameters.new(theme: "lista", layout: "devices", areas: [ cozinha.id, sala.id ])
      expect(Onboarding::Steps::DashboardStep.wizard?(ctx, all)).to be(false)
    end
  end

  it "quem não administra o local não entra" do
    other = create(:user, tenant: tenant, role: "member")
    within(tenant) { SiteMembership.create!(site: site, user: other, role: "resident") }
    sign_in(other)
    get "/paineis/#{dashboard.id}/arrumar", params: { view: "v-coz" }
    expect(response).to have_http_status(:forbidden).or redirect_to(anything)
    get "/configuracoes/paineis/arrumacao/#{site.id}"
    expect(response).not_to have_http_status(:ok)
  end
end
