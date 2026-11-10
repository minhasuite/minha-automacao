require "rails_helper"

# Topo discreto do painel (Ss::PageComponent compacto: local · data, o nome da visão e o editar só
# em ícone, sem "Painéis") e o "Falar com a casa" como botão flutuante da gem em todas as telas.
RSpec.describe "Cabeçalho do painel e botão flutuante de voz" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:area) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let!(:device) { within(tenant) { create(:device, site: site, area: area, name: "Lâmpada Sala") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Luz", value: false) } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })
  def page = Nokogiri::HTML(response.body)
  def dashboard = within(tenant) { Dashboard.ensure_for(site).first }

  before { within(tenant) { create(:site, name: "Praia") } }

  it "visão de cômodo: topo compacto sem degradê, editar só ícone, sem Painéis e sem Falar no topo" do
    sign_in
    get "/", params: { view: "a-#{area.id}" }
    doc = page
    head = doc.at_css("main .ss-page.is-compact")
    expect(head).to be_present
    expect(doc.at_css("main .ss-hero")).to be_nil
    expect(head.at_css(".ss-page-eyebrow").text).to eq("Casa · #{I18n.l(Date.current, format: :long)}")
    expect(head.at_css("h1.ss-page-title").text).to eq("Sala")
    edit = head.at_css(".ss-page-actions a.ss-icon-btn[aria-label='Editar painel']")
    expect(edit["title"]).to eq("Editar painel")
    expect(edit.text.strip).to be_empty
    expect(head.css(".ss-page-actions > *").size).to eq(1)
    expect(head.to_html).not_to include("/paineis\"", "microphone", "assist#open")
    expect(doc.at_css("main a[href='/locais/#{site.id}/paineis']")).to be_nil
  end

  it "o Falar é o botão flutuante do layout, uma vez, fora do main, no painel e nas outras telas" do
    sign_in
    [ "/", "/notificacoes", "/locais/#{site.id}/paineis" ].each do |path|
      get path
      expect(response).to have_http_status(:ok)
      fabs = page.css("button.ss-fab")
      expect(fabs.size).to eq(1), path
      fab = fabs.first
      expect(fab["id"]).to eq("assist-fab")
      expect(fab["aria-label"]).to eq("Falar com a casa")
      expect(fab["data-action"]).to eq("assist#open")
      expect(fab.ancestors("main")).to be_empty
      expect(page.at_css("[data-controller=assist][data-assist-site-value='#{site.id}'] dialog[data-assist-target=dialog]")).to be_present
    end
  end

  it "leitor do local (sem comando) não ganha o botão" do
    reader = create(:user, tenant: tenant, role: "member")
    within(tenant) { create(:site_membership, site: site, user: reader, role: "viewer") }
    sign_in(reader)
    get "/"
    expect(response).to have_http_status(:ok)
    expect(page.css(".ss-fab")).to be_empty
  end

  it "pelo app (AppScreen) a tela não traz o botão (o app tem o dele)" do
    d = dashboard
    sign_in
    env = { AppScreen::ENV_KEY => user.id }
    get "/paineis/#{d.id}", env: env
    expect(response.body).not_to include("ss-fab")
  end
end
