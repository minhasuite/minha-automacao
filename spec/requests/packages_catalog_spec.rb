require "rails_helper"

# Aba "Explorar" da loja de pacotes (Packages::Catalog): o catálogo oficial
# (minhasuite/minha-automacao-marketplace) aponta; instalar segue pela prévia
# de sempre. Os fixtures são cópias do index.json e de um pacote oficial.
RSpec.describe "Pacotes: catálogo (Explorar)" do
  let(:user) { create(:user, role: "owner") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:catalog) { Rails.root.join("spec/fixtures/files/packages_catalog.json").read }
  let(:luz) { Rails.root.join("spec/fixtures/files/pacote_luz_por_movimento.json").read }
  let(:luz_raw) { "https://raw.githubusercontent.com/minhasuite/minha-automacao-marketplace/main/packages/luz-por-movimento/minha-automacao.json" }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  before do
    Rails.cache.clear
    stub_request(:get, Packages::Catalog::OFFICIAL).to_return(body: catalog)
    stub_request(:get, luz_raw).to_return(body: luz)
  end

  it "lista o catálogo oficial, filtra, pré-visualiza e instala o pacote pela URL do catálogo" do
    sign_in
    get "/locais/#{site.id}/pacotes?tab=explorar"
    expect(response.body).to include("Luz por movimento", "Aviso de porta aberta", "Modo da casa", "Oficial", "Ver o que entra")

    get "/locais/#{site.id}/pacotes", params: { tab: "explorar", q: "porta" }
    expect(response.body).to include("Aviso de porta aberta")
    expect(response.body).not_to include("Modo da casa")
    get "/locais/#{site.id}/pacotes", params: { tab: "explorar", tag: "helper" }
    expect(response.body).to include("Modo da casa")
    expect(response.body).not_to include("Aviso de porta aberta")

    url = JSON.parse(catalog)["packages"].find { |p| p["key"] == "luz-por-movimento" }["url"]
    post "/locais/#{site.id}/pacotes/previa", params: { url: url }
    expect(response.body).to include("Luz por movimento", "Instalar")
    post "/locais/#{site.id}/pacotes/instalar", params: { url: url }
    package = within(tenant) { site.packages.find_by!(key: "luz-por-movimento") }
    expect(package.installed.size).to eq(1)

    get "/locais/#{site.id}/pacotes?tab=explorar"
    expect(response.body).to include("Instalado · 1.0.0", "Ver de novo")

    # O app abre a mesma aba (tela do servidor), com o botão da prévia.
    get "/api/v1/screen", params: { path: "/locais/#{site.id}/pacotes?tab=explorar" }, headers: auth_headers(user)
    expect(response.parsed_body.dig("meta", "status")).to eq(200)
    blocks = response.parsed_body.dig("data", "page", "blocks").to_json
    expect(blocks).to include("Aviso de porta aberta", "Ver o que entra", "/pacotes/previa")
  end

  it "fica de fora a entrada inválida; catálogo que não responde vira aviso; outros catálogos somam" do
    bad = { "format" => 1, "name" => "Outro", "packages" => [
      { "key" => "x", "name" => "Chave curta", "url" => "https://github.com/a/b" },
      { "key" => "sem-fonte", "name" => "Sem fonte", "url" => "ftp://nada" },
      { "key" => "luz-por-movimento", "name" => "Cópia", "url" => "https://github.com/a/copia" },
      { "key" => "de-terceiro", "name" => "De terceiro", "url" => "https://gitlab.com/g/r", "official" => true } ] }
    stub_request(:get, "https://outro.teste/index.json").to_return(body: bad.to_json)
    stub_request(:get, "https://fora.teste/index.json").to_return(status: 500)
    stub_const("ENV", ENV.to_h.merge("PACKAGES_CATALOGS" => "#{Packages::Catalog::OFFICIAL} https://outro.teste/index.json https://fora.teste/index.json http://inseguro.teste/x.json"))

    result = Packages::Catalog.call
    expect(result.entries.map(&:key)).to eq(%w[luz-por-movimento aviso-porta-aberta modo-da-casa de-terceiro])
    expect(result.entries.find { |e| e.key == "luz-por-movimento" }.name).to eq("Luz por movimento") # o primeiro catálogo vale
    expect(result.entries.last).to have_attributes(official: false, catalog: "Outro") # só o oficial é oficial
    expect(result.errors.join).to include("fora.teste")

    sign_in
    get "/locais/#{site.id}/pacotes?tab=explorar"
    expect(response.body).to include("De terceiro", "não respondeu")
  end
end
