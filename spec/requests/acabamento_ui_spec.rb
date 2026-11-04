require "rails_helper"

# Acabamento de UI/UX: o que muda comportamento visível na web.
RSpec.describe "Acabamento de UI/UX" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }

  before { post("/entrar", params: { email: user.email, password: "12345678" }) }

  it "a página do local não lista os virtuais internos de helpers em Sem área" do
    within(tenant) { create(:device, site: site, name: "Sensor solto", driver: "virtual") }
    post "/locais/#{site.id}/helpers", params: { tipo: "toggle", helper: { name: "Férias", initial: "0" } }
    get "/locais/#{site.id}"
    expect(response.body).to include("Sensor solto", "Virtual")
    expect(response.body).not_to include(">Helpers</span><span")
    expect(within(tenant) { site.devices.listed.pluck(:name) }).to eq([ "Sensor solto" ])
  end

  it "editar o rascunho do painel avisa que salvou" do
    d = within(tenant) { Dashboard.ensure_for(site).first }
    patch "/paineis/#{d.id}/rascunho", params: { op: "add_view", title: "Cozinha" }
    follow_redirect!
    expect(response.body).to include("Salvo no rascunho")
    expect(response.body).to include('class="ss-iconpick"', 'name="icon"')
  end

  it "ícone escolhido pelo desenho no helper e a zona de perigo do Sistema" do
    post "/locais/#{site.id}/helpers", params: { tipo: "toggle", helper: { name: "Férias", initial: "0", icon: "sun" } }
    p = within(tenant) { site.points.helpers.last }
    get "/helpers/#{p.id}/editar"
    expect(response.body).to include(%(name="helper[icon]" value="sun")).and match(/aria-checked="true"[^>]*data-name="sun"/m)
    expect(response.body).not_to include('data-name="chevron-down"')
    get "/configuracoes/sistema"
    expect(response.body).to include("ss-danger-zone", "Digite ZERAR")
  end

  it "rodada 2: ações em massa na barra flutuante, Publicar diz por quê e endereço da visão recolhido" do
    within(tenant) { create(:device, site: site, name: "Lâmpada", driver: "virtual") }
    get "/locais/#{site.id}/dispositivos"
    expect(response.body).to include('class="ss-selection-bar"', 'data-ss-table-target="check"', "ma-bulk-area", "ss-badge-dot", "aria-sort=\"ascending\"")
    get "/locais/#{site.id}/dispositivos", params: { sort: "area", dir: "desc" }
    expect(response.body).to include('aria-sort="descending"')
    get "/locais/#{site.id}/dispositivos", params: { sort: "drop table", dir: "x" }
    expect(response).to have_http_status(:ok)
    d = within(tenant) { Dashboard.ensure_for(site).first }
    get "/paineis/#{d.id}/editar"
    expect(response.body).to include("Endereço da visão", "ss-summary")
    patch "/paineis/#{d.id}", params: { dashboard: { name: "Casa" } }
    post "/paineis/#{d.id}/publicar"
    get "/paineis/#{d.id}/editar"
    expect(response.body).to include("Sem mudanças para publicar", 'aria-describedby="publish-why"')
    get "/locais/#{site.id}/automacoes"
    expect(response.body).to include("Criar a primeira", "Voltar a Casa")
  end

  it "rodada 2: pular para o conteúdo e menu do celular com aria-expanded" do
    get "/"
    follow_redirect! while response.redirect?
    expect(response.body).to include('href="#conteudo"', 'id="conteudo"', 'aria-expanded="false"')
  end

  it "rodada 3: nome sem repetir, sem sinal explicado, soma só do que está no ar e situação do aparelho" do
    names = within(tenant) do
      dev = create(:device, site: site, name: "PIS Ilum Interna")
      esc = create(:device, site: site, name: "Iluminação Escada")
      tom = create(:device, site: site, name: "Tomada 4 Canais")
      [ create(:point, device: dev, name: "Iluminação Interna").display_names, create(:point, device: esc, name: "Liga/desliga").display_names,
        create(:point, device: tom, name: "Interruptor 3").display_names, create(:point, device: tom, name: "Luz de fundo").display_names,
        create(:point, device: tom, name: "Potência", capability: "measure", unit: "W", device_class: "power").display_names ]
    end
    expect(names).to eq([ [ "Iluminação Interna", nil ], [ "Iluminação Escada", nil ], [ "Tomada 4 Canais", "Interruptor 3" ],
                          [ "Luz de fundo", "Tomada 4 Canais" ], [ "Tomada 4 Canais", "Potência" ] ])

    off = within(tenant) do
      d = create(:device, site: site, name: "Medidor", driver: "tuya_local", status: "offline", poll_s: nil)
      p = create(:point, device: d, name: "Potência", capability: "measure", unit: "W", device_class: "power")
      p.report!(150, quality: "unavailable")
      create(:device, site: site, name: "Câmera nova", driver: "tuya_local", poll_s: nil)
      create(:device, site: site, name: "Casa Z", driver: "virtual")
      p
    end
    html = ApplicationController.helpers
    expect(html.point_status_note(off)).to start_with("Sem sinal")
    d = within(tenant) { Dashboard.ensure_for(site).first }
    stat = { "id" => "x", "type" => "stat", "query" => { "device_class" => "power" }, "aggregate" => "sum" }
    data = within(tenant) { Dashboards::Resolver.new(d, role: "owner", definition: { "views" => [ { "id" => "v", "sections" => [ { "id" => "s", "widgets" => [ stat ] } ] } ] }).call }
    expect(data.dig("views", 0, "sections", 0, "widgets", 0, "data", "text")).to eq("—")

    get "/locais/#{site.id}/dispositivos"
    expect(response.body).to include("Sem sinal", "Sem contato", "Não informa o estado sozinho")
    expect(response.body.index("Câmera nova")).to be < response.body.index("Casa Z") # sem acento na ordem
    get "/pontos/#{off.id}"
    expect(response.body).to include("Sem sinal", "o aparelho não respondeu")
  end
end
