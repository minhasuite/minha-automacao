require "rails_helper"

# Menu: o Início leva o nome do painel padrão (sem repetir o painel) e Locais
# mora em Configurações.
RSpec.describe "Menu lateral" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }

  before { post "/entrar", params: { email: user.email, password: "12345678" } }

  def nav_labels = Nokogiri::HTML(response.body).css("nav a").map { |a| a.text.squish }

  it "o Início é o painel padrão do local, com o nome dele e sem duplicar" do
    within(tenant) do
      Dashboard.create!(site: site, name: "Automático", kind: "home", auto: true, position: 0)
      Dashboard.create!(site: site, name: "Minha casa", kind: "custom", site_default: true, sidebar: true, position: 5,
                        definition: { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [] } ] })
      Dashboard.create!(site: site, name: "Energia", kind: "custom", sidebar: true, position: 6,
                        definition: { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [] } ] })
    end
    get "/"
    labels = nav_labels
    expect(labels.count("Minha casa")).to eq(1)
    expect(labels).to include("Energia")
    expect(labels).not_to include("Início")
    expect(response.body).to include("Minha casa")
  end

  it "Locais saiu do menu lateral e está em Configurações" do
    get "/"
    expect(Nokogiri::HTML(response.body).css("nav a[href='/locais']")).to be_empty
    get "/configuracoes/sistema"
    expect(response.body).to include(%(href="/locais"))
  end
end
