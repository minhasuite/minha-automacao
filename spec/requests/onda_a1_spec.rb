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
end
