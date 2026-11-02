require "rails_helper"

# ondaA1: telas da paridade HA (andares, rótulos, categorias, aliases, Expor,
# unidades, YAML, todo e calendário local).
RSpec.describe "Web ondaA1: paridade HA" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let(:site) { within(tenant) { create(:site) } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  before do
    Onboarding.finish!(tenant)
    sign_in
  end

  it "A1: cria andar com nível e o local agrupa as áreas por andar" do
    post "/locais/#{site.id}/areas", params: { area: { name: "Térreo", kind: "floor", level: 0 } }
    floor = within(tenant) { site.areas.find_by!(name: "Térreo") }
    expect(floor.level).to eq(0)
    post "/locais/#{site.id}/areas", params: { area: { name: "Cozinha", parent_id: floor.id } }
    get "/locais/#{site.id}"
    expect(response.body).to include("Térreo", "Cozinha", "Novo andar")
    get "/areas/#{floor.id}"
    expect(response.body).to include("Áreas deste andar", "Cozinha")
    get "/locais/#{site.id}/areas/novo?kind=floor"
    expect(response.body).to include("Nível do andar")
  end

  it "A2: categorias agrupam as listas, rótulos filtram e a tela de rótulos edita cor e junta nomes" do
    a1, a2 = within(tenant) do
      [ site.automations.create!(name: "Acender varanda", category: "Iluminação", label_list: "noite"),
        site.automations.create!(name: "Alarme", category: "Segurança") ]
    end
    get "/locais/#{site.id}/automacoes"
    expect(response.body).to include("ss-group", "Iluminação", "Segurança", "noite")
    get "/locais/#{site.id}/automacoes", params: { categoria: "Segurança" }
    expect(response.body).to include("Alarme")
    expect(response.body).not_to include("Acender varanda")
    patch "/automacoes/#{a2.id}", params: { automation: { label_list: "Noite, alarme" } }
    expect(within(tenant) { a2.reload.label_names }).to eq(%w[alarme noite])

    tag = within(tenant) { Tag.find_by!(name: "alarme") }
    get "/configuracoes/rotulos"
    expect(response.body).to include("alarme", "noite", "automações e scripts")
    patch "/configuracoes/rotulos/#{tag.id}", params: { tag: { name: "noite", color: "#ff0000" } }
    expect(within(tenant) { [ Tag.exists?(tag.id), a2.reload.label_names, a1.reload.label_names ] }).to eq([ false, [ "noite" ], [ "noite" ] ])
    noite = within(tenant) { Tag.find_by!(name: "noite") }
    patch "/configuracoes/rotulos/#{noite.id}", params: { tag: { name: "noite", color: "#00aa00" } }
    expect(within(tenant) { noite.reload.color }).to eq("#00aa00")
  end

  it "A3: tela Expor marca em massa por assistente e respeita o risco crítico" do
    pts = within(tenant) do
      dev = create(:device, site: site, name: "Teste aparelho")
      [ create(:point, site: site, device: dev, name: "Teste luz", aliases: [ "abajur" ]),
        create(:point, site: site, device: dev, name: "Teste portão", risk: "critical") ]
    end
    get "/locais/#{site.id}/expor"
    expect(response.body).to include("Expor a assistentes", "Teste luz", "Apelidos: abajur", "Assist", "Alexa")
    get "/locais/#{site.id}/expor", params: { q: "abajur" }
    expect(response.body).not_to include("Teste portão")
    patch "/locais/#{site.id}/expor", params: { x: { pts[0].id => { assist: "0", alexa: "1" }, pts[1].id => { alexa: "1" } } }
    expect(flash[:alert]).to include("confirmação")
    expect(within(tenant) { [ pts[0].reload.expose["assist"], pts[0].alexa_exposed, pts[1].reload.alexa_exposed ] }).to eq([ false, true, false ])
    patch "/locais/#{site.id}/expor", params: { confirm: "1", x: { pts[1].id => { alexa: "1" } } }
    expect(within(tenant) { pts[1].reload.alexa_exposed }).to be true
  end

  it "A4: formulário do local salva unidades, moeda, elevação, país e idioma" do
    patch "/locais/#{site.id}", params: { site: { unit_system: "imperial", currency: "eur", elevation: 900, country: "pt", language: "es" } }
    expect(within(tenant) { site.reload.attributes.values_at("unit_system", "currency", "elevation", "country", "language") }).to eq([ "imperial", "EUR", 900, "PT", "es" ])
    get "/locais/#{site.id}/editar"
    expect(response.body).to include("Sistema de unidades", "Imperial")
  end
end
