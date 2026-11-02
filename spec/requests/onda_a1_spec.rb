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
end
