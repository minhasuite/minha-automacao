require "rails_helper"

# Painéis do HA → painéis daqui com a mesma disposição (Dashboards::HaImport +
# Integrations::HaDashboards), com um HA falso. Nunca fala com um HA de verdade.
RSpec.describe "Painéis importados do HA" do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa Teste") } }
  let(:fixture) { JSON.parse(Rails.root.join("spec/fixtures/files/ha_paineis.json").read) }
  let(:fake) { FakeHaTransport.new(fixture) }
  let(:integration) { within(tenant) { site.integrations.create!(driver: "home_assistant", name: "HA", settings: { "url" => "http://ha.teste:8123" }) } }
  let(:images) { ->(_i, path) { path.include?("home.jpg") ? [ "\xFF\xD8\xFFteste".b, "image/jpeg" ] : nil } }
  let(:src) { Integrations::HaDashboards::SOURCE }

  # Pontos com o par do HA (o que o importador da migração deixa no ExternalRef).
  let!(:pts) do
    within(tenant) do
      dev = create(:device, site: site, name: "Teste Aparelhos", driver: "virtual")
      mk = ->(ent, cap = "onoff") { create(:point, site: site, device: dev, name: ent, key: ent.tr(".", "_"), capability: cap).tap { |p| ExternalRef.link!(site, src, ent, kind: "entity", target: p) } }
      list = %w[light.teto_teste light.l1 light.l2 light.l3 light.l4 light.l5 light.l6 light.l7 light.l8 light.l9].to_h { |e| [ e, mk.(e) ] }
      list["sensor.temperatura_teste"] = mk.("sensor.temperatura_teste", "measure")
      list["sensor.resumo_teste"] = mk.("sensor.resumo_teste", "measure")
      list["person.teste"] = mk.("person.teste", "text")
      cam = create(:device, site: site, name: "Teste Câmera", driver: "go2rtc")
      list["camera.camera_teste"] = create(:point, site: site, device: cam, name: "Câmera", key: "cam_teste", capability: "stream").tap { |p| ExternalRef.link!(site, src, "camera.camera_teste", kind: "entity", target: p) }
      area = create(:area, site: site, name: "Cozinha Teste")
      ExternalRef.link!(site, src, "area:cozinha_teste", kind: "area", target: area)
      scene = site.scenes.create!(name: "Noite Teste", items: [ { "point_id" => list["light.l1"].id, "command" => "off" } ])
      ExternalRef.link!(site, src, "scene.noite_teste", kind: "scene", target: scene)
      script = site.automations.create!(name: "Boa noite teste", kind: "script")
      ExternalRef.link!(site, src, "script.boa_noite_teste", kind: "script", target: script)
      list.merge("area" => area, "scene" => scene, "script" => script)
    end
  end

  def import! = within(tenant) { Integrations::HaDashboards.call(site, integration, transport: fake, images: images) }
  def widgets(view) = view["sections"].flat_map { |s| s["widgets"] }

  it "recria cada painel, visão, seção e card na mesma disposição, e anota o que não veio" do
    report = import!
    expect(report.dashboards.map(&:name)).to eq(%w[Casa Mobile Energia])
    casa, mobile, energia = report.dashboards.map(&:reload)
    defn = casa.definition
    expect(within(tenant) { Dashboards::Schema.errors(defn) }).to eq([])

    home, cozinha = defn["views"]
    expect(home).to include("title" => "Início", "path" => "home", "icon" => "mdi:home", "type" => "sections")
    theme_key = within(tenant) { DashboardTheme.sole }.key
    expect(home["theme"]).to include("key" => theme_key, "glass" => true)
    expect(home["theme"]["image"]).to start_with("/rails/active_storage/blobs/")
    expect(cozinha).to include("subview" => true, "back_path" => "home")
    expect(cozinha["theme"]).not_to have_key("image") # o fundo da cozinha não veio
    expect(within(tenant) { DashboardTheme.sole }).to have_attributes(accent: "#3366ff", accent2: "#ff8800", glass: true)

    # badges: atributo do sensor, "diferente de" na visibilidade; sem par = fora
    expect(home["badges"].size).to eq(2)
    expect(home["badges"][0]).to include("type" => "stat", "bind" => pts["sensor.resumo_teste"].id, "attribute" => "luzes", "icon" => "mdi:lightbulb-group-outline")
    expect(home["badges"][1]["visible_if"]).to eq("state" => { "point" => pts["person.teste"].id, "not" => "unknown" })

    # seções: 2 de 3 colunas → 8 de 12; 1 coluna → 4
    s1, s2 = home["sections"]
    expect(s1["span"]).to eq("mobile" => 12, "tablet" => 12, "desktop" => 8)
    expect(s2["span"]).to eq("mobile" => 12, "tablet" => 6, "desktop" => 4)

    w1 = s1["widgets"]
    expect(w1.map { |w| w["type"] }).to eq(%w[heading area_card markdown tile scene_bar button markdown])
    expect(w1[0]).to include("title" => "Cômodos", "icon" => "mdi:floor-plan", "span" => { "mobile" => 12, "tablet" => 12, "desktop" => 12 })
    expect(w1[1]).to include("area" => pts["area"].id, "visible_if" => { "screen" => %w[tablet desktop] }, "span" => { "mobile" => 6, "tablet" => 6, "desktop" => 6 })
    expect(cozinha["area"]).to eq(pts["area"].id) # o cartão de área abre a visão ligada à área
    expect(w1[3]).to include("bind" => pts["light.teto_teste"].id, "label" => "Teto", "icon" => "mdi:ceiling-light", "color" => "amber",
                             "features" => [ "brightness" ], "hold_action" => { "action" => "more_info" })
    expect(w1[4]).to include("scenes" => [ pts["scene"].id ])
    script_point = within(tenant) { Scripts.point_for(pts["script"]) }
    expect(w1[5]).to include("bind" => script_point.id, "span" => { "mobile" => 3, "tablet" => 3, "desktop" => 3 },
                             "tap_action" => { "action" => "command", "point" => script_point.id, "command" => "run" })
    expect(w1[6]["text"]).to include("custom:cartao-que-nao-existe")

    w2 = s2["widgets"]
    expect(w2.map { |w| w["type"] }).to eq(%w[heading markdown camera stack stack tile query_list chart tile])
    temp = { "numeric" => { "point" => pts["sensor.temperatura_teste"].id, "above" => 10.0 } }
    expect(w2.first["visible_if"]).to eq(temp) # a condição da seção vale para cada card
    expect(w2[0]["tap_action"]["navigation_path"]).to eq("/paineis/#{energia.id}?view=home")
    expect(w2[1]["text"]).to include("°C").and include("{{")
    expect(w2[2]).to include("bind" => pts["camera.camera_teste"].id, "live" => false)
    expect(w2[3]["widgets"].map { |g| g["binds"].size }).to eq([ 8, 1 ]) # 9 luzes (uma sem par) em grupos de 8
    expect(w2[4]["widgets"].map { |w| w["type"] }).to eq(%w[tile stat])
    expect(w2[5]["visible_if"]["all"]).to contain_exactly(temp, { "state" => { "point" => pts["light.teto_teste"].id, "is" => "on" } })
    expect(w2[6]["query"]).to eq("capability" => "media", "state" => "on", "quality" => "good")
    expect(w2[7]).to include("range" => "7d")
    expect(w2[8]["visible_if"]["all"]).to include("state" => { "point" => pts["light.teto_teste"].id, "is" => "off" }) # a condição por pessoa cai

    notes = report.notes.join("\n")
    expect(notes).to include("sensor.sem_par", "area_que_nao_existe", "custom:cartao-que-nao-existe", "coisa-nova",
                             "condição por pessoa", "1 entidade(s) da lista sem par")

    expect(widgets(mobile.definition["views"].first).first["span"]).to eq("mobile" => 12, "tablet" => 12, "desktop" => 12)
    expect(energia.definition["views"].first["sections"].flat_map { |s| s["widgets"] }.map { |w| w["type"] }).to eq(%w[energy_breakdown])
    expect(energia.roles).to eq(%w[technician owner])
    expect([ casa.site_default, casa.app_default, mobile.app_default, mobile.site_default ]).to eq([ true, false, true, false ])
    expect(casa.icon).to eq("mdi:home")
  end

  it "importar de novo publica versão nova no mesmo painel; web e app abrem cada um o seu" do
    first = import!.dashboards.map(&:id)
    expect { import! }.not_to(change { within(tenant) { Dashboard.count } })
    expect(import!.dashboards.map(&:id)).to eq(first)
    casa = within(tenant) { Dashboard.find(first.first) }
    expect(casa.version).to be >= 3

    within(tenant) { create(:site_membership, site: site, user: user, role: "owner") } unless site.role_for(user)
    role = site.role_for(user)
    expect(within(tenant) { Dashboard.default_for(site, user, role).name }).to eq("Casa")
    expect(within(tenant) { Dashboard.default_for(site, user, role, app: true).name }).to eq("Mobile")
    user.update!(dashboard_prefs: { "app:#{site.id}" => first.last })
    expect(within(tenant) { Dashboard.default_for(site, user, role, app: true).name }).to eq("Energia")
  end

  it "visibilidade nova: estado diferente de e todas as condições" do
    p = pts["light.teto_teste"]
    within(tenant) { p.update!(value: "off") }
    r = within(tenant) { Dashboards::Resolver.new(site.dashboards.create!(name: "Teste", kind: "custom", auto: false, definition: { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [] } ] }), role: "owner") }
    expect(r.send(:condition_ok?, { "state" => { "point" => p.id, "not" => "on" } }, {})).to be(true)
    expect(r.send(:condition_ok?, { "state" => { "point" => p.id, "not" => %w[off] } }, {})).to be(false)
    expect(r.send(:condition_ok?, { "all" => [ { "state" => { "point" => p.id, "is" => "off" } }, { "state" => { "point" => p.id, "not" => "on" } } ] }, {})).to be(true)
    expect(Dashboards::Schema.errors({ "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => [
      { "id" => "w", "type" => "tile", "bind" => p.id, "visible_if" => { "all" => [ { "state" => { "point" => p.id, "not" => "on" } } ] } }
    ] } ] } ] })).to eq([])
  end

  it "ícone do HA (mdi:) na web; nome desconhecido ou estranho cai no padrão" do
    helper = Object.new.extend(ApplicationHelper)
    expect(helper.icon("mdi:stove")).to include('data-icon="mdi:stove"', 'fill="currentColor"', "<path d=")
    expect(helper.icon("mdi:nao-existe")).to include('data-icon="view-grid"')
    expect(helper.icon("../../etc/passwd")).to include("<svg")
    expect(within(tenant) { site.dashboards.new(name: "X", kind: "custom", icon: "mdi:stove") }.tap(&:validate).errors[:icon]).to be_empty
    expect(within(tenant) { site.dashboards.new(name: "X", kind: "custom", icon: "mdi:nao-existe") }.tap(&:validate).errors[:icon]).not_to be_empty
  end

  it "no assistente Migre do HA: o botão importa os painéis e a tela mostra o resultado" do
    integration.merge_secrets!("token" => "token-teste")
    allow(Integrations::HaMigration).to receive(:transport_for).and_return(fake)
    allow(Integrations::HaDashboards).to receive(:transport_for).and_return(fake)
    allow(Integrations::HaDashboards).to receive(:download) { |i, path| images.call(i, path) }
    within(tenant) { create(:site_membership, site: site, user: user, role: "owner") } unless site.role_for(user)
    post("/entrar", params: { email: user.email, password: "12345678" })
    get "/locais/#{site.id}/migrar-do-ha"
    expect(response.body).to include("Painéis do Home Assistant", "Importar painéis")
    perform_enqueued_jobs { post "/locais/#{site.id}/migrar-do-ha/paineis" }
    get "/locais/#{site.id}/migrar-do-ha"
    expect(response.body).to include("3 painéis importados.", "Importar de novo", "O que não veio igual")
    casa = within(tenant) { Dashboard.find_by!(name: "Casa") }
    get "/paineis/#{casa.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Cômodos", 'data-icon="mdi:floor-plan"')
    get "/paineis/#{casa.id}?view=cozinha"
    expect(response.body).to include("Início") # o voltar da subvisão
    api = ApiToken.issue(user, device_name: "Teste")
    get "/api/v1/sites/#{site.id}/dashboards", headers: { "Authorization" => "Bearer #{api[1]}" }
    expect(JSON.parse(response.body)["data"].find { |d| d["default"] }["name"]).to eq("Mobile")
  end
end
