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
    expect(response.body).to include('class="ss-icons"', 'name="icon"')
  end

  it "ícone escolhido pelo desenho no helper e a zona de perigo do Sistema" do
    post "/locais/#{site.id}/helpers", params: { tipo: "toggle", helper: { name: "Férias", initial: "0", icon: "sun" } }
    p = within(tenant) { site.points.helpers.last }
    get "/helpers/#{p.id}/editar"
    expect(response.body).to match(/name="helper\[icon\]" value="sun" checked/)
    expect(response.body).not_to include('value="chevron-down"')
    get "/configuracoes/sistema"
    expect(response.body).to include("ss-danger-zone", "Digite ZERAR")
  end
end
