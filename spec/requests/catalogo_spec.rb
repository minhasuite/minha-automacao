require "rails_helper"

# catalogo (grupo 9): toda integração do catálogo aparece na tela de adicionar
# e abre o formulário (o gerado dos campos ou o próprio), nos três idiomas.
RSpec.describe "Catálogo de integrações (grupo 9)" do
  let(:user) { create(:user) }
  let!(:site) { within(user.tenant) { create(:site, name: "Casa") } }

  before { post("/entrar", params: { email: user.email, password: "12345678" }) }

  def schema_plugins = Integrations.plugins.select { |p| p < Integrations::SchemaPlugin }

  it "cada SchemaPlugin está no catálogo e o formulário sai dos campos" do
    expect(schema_plugins.size).to be >= 5
    get "/locais/#{site.id}/integracoes"
    expect(response.body).to include(*schema_plugins.map { |p| ERB::Util.html_escape(p.title) })
    schema_plugins.each do |p|
      get "/locais/#{site.id}/integracoes/nova", params: { tipo: p.key }
      expect(response).to have_http_status(:ok)
      p.fields.each { |f| expect(response.body).to include("integration[#{f.key}]", ERB::Util.html_escape(p.field_label(f.key))) }
    end
  end

  it "o formulário gerado fala o idioma da pessoa" do
    get "/locais/#{site.id}/integracoes/nova", params: { tipo: "tplink" }, headers: { "Accept-Language" => "en" }
    expect(response.body).to include("Device line", "Tapo / new Kasa (TP-Link account)")
  end

  it "campo obrigatório vazio volta para o formulário com o aviso" do
    post "/locais/#{site.id}/integracoes", params: { tipo: "fully_kiosk", integration: { host: "192.0.2.7" } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Preencha: Senha.")
  end
end
