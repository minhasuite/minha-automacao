require "rails_helper"

# Assistente da câmera Tapo: formulário (conta da câmera, senha da nuvem,
# controle local) e o Reconfigurar sem mostrar as senhas guardadas.
RSpec.describe "Câmera Tapo no assistente" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { ActsAsTenant.with_tenant(tenant) { create(:site, name: "Casa") } }

  before { post("/entrar", params: { email: user.email, password: "12345678" }) }

  it "mostra o formulário, cria pela câmera e o Reconfigurar não devolve senha" do
    get "/locais/#{site.id}/integracoes", params: { q: "tapo" }
    expect(response.body).to include("Câmera Tapo (TP-Link)")
    get "/locais/#{site.id}/integracoes/nova", params: { tipo: "tapo" }
    expect(response.body).to include("Usuário da conta da câmera", "Senha da nuvem (opcional)", "Compatibilidade com terceiros")

    allow(Onvif).to receive(:inventory).and_return({ "id" => "onvif:10.0.0.30", "kind" => "go2rtc", "model" => "C200", "address" => { "host" => "10.0.0.30" },
                                                     "points" => [ { "name" => "mainStream", "capability" => "stream", "address" => { "path" => "/stream1" } } ] })
    post "/locais/#{site.id}/integracoes", params: { tipo: "tapo", integration: { host: "10.0.0.30", username: "conta", password: "s3gr3do", cloud_password: "nuv3m", control: "1" } }
    integration = ActsAsTenant.with_tenant(tenant) { Integration.find_by!(driver: "tapo") }
    expect(integration.found.first["points"].map { |p| p["name"] }).to include("Vídeo (alta)", "Modo privacidade", "Sirene")
    expect(Onvif).to have_received(:inventory).with(hash_including("host" => "10.0.0.30", "onvif_port" => 2020, "username" => "conta"), "s3gr3do")

    get "/integracoes/#{integration.id}/conectar"
    expect(response.body).to include("10.0.0.30")
    expect(response.body).not_to include("s3gr3do", "nuv3m")
  end
end
