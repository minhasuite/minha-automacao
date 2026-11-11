require "rails_helper"

# Apps: memória marcada e "Conectar" (manifesto `connect`) na página do app.
RSpec.describe "Aplicativos: ligar ao Minha Automação" do
  include ActiveJob::TestHelper

  let(:owner) { create(:user, email: "dono@ex.com") }
  let(:tenant) { owner.tenant }
  let(:base) { "http://supervisor:8099" }
  let!(:site) { ActsAsTenant.with_tenant(tenant) { create(:site, name: "Casa") } }

  def stub_status(key, state = "running")
    stub_request(:get, "#{base}/apps/#{key}").to_return(status: 200, body: { data: { "key" => key, "installed" => true, "state" => state, "options" => {} } }.to_json)
  end

  around do |ex|
    old = ENV.values_at("SUPERVISOR_URL", "SUPERVISOR_TOKEN", "APP_HOST")
    ENV.update("SUPERVISOR_URL" => base, "SUPERVISOR_TOKEN" => "x" * 40)
    ENV.delete("APP_HOST")
    ex.run
  ensure
    ENV["SUPERVISOR_URL"], ENV["SUPERVISOR_TOKEN"], ENV["APP_HOST"] = old
  end

  def sign_in(host)
    host! host
    post("/entrar", params: { email: owner.email, password: "12345678" })
  end

  before { sign_in("192.168.68.10") }

  it "a página mostra a memória, o aviso de pesado e o Conectar só com o app rodando" do
    stub_status("ollama")
    get "/configuracoes/aplicativos/ollama"
    expect(response.body).to include("~2048 MB", "Pesado", "Ligar ao Minha Automação", "Conectar")
    stub_status("wg_easy", "exited")
    get "/configuracoes/aplicativos/wg_easy"
    expect(response.body).to include("NET_ADMIN")
    stub_status("adguard_home", "exited")
    get "/configuracoes/aplicativos/adguard_home"
    expect(response.body).to include("Inicie o aplicativo antes de conectar")
    stub_request(:get, "#{base}/apps").to_return(status: 200, body: { data: [] }.to_json)
    get "/configuracoes/aplicativos/loja"
    expect(response.body).to include("Pesado")
  end

  it "integração: vai ao formulário preenchido com o IP do servidor e libera o IP" do
    post "/configuracoes/aplicativos/adguard_home/conectar"
    expect(response).to redirect_to(%r{/locais/#{site.id}/integracoes/nova\?.*host=192\.168\.68\.10.*port=3080.*tipo=adguard})
    expect(tenant.reload.http_allow).to eq([ "192.168.68.10" ])
    expect(AuditEvent.where(action: "app.connect", auditable_type: "App")).to exist
    follow_redirect!
    expect(response.body).to include("192.168.68.10", "3080")
  end

  it "IA: cria a conta do Ollama com o endereço e baixa o modelo pela fila; sem IP conhecido avisa" do
    expect { post "/configuracoes/aplicativos/ollama/conectar" }.to have_enqueued_job(AiPrepareJob)
    acc = ActsAsTenant.with_tenant(tenant) { AiAccount.find_by!(provider: "ollama") }
    expect([ acc.base_url, acc.model, acc.enabled ]).to eq([ "http://192.168.68.10:11434", "qwen2.5:1.5b", true ])
    expect(response).to redirect_to("/configuracoes/ia#ollama")
    post "/configuracoes/aplicativos/wyoming_piper/conectar"
    expect(ActsAsTenant.with_tenant(tenant) { AiAccount.find_by!(provider: "wyoming").base_url }).to eq("tcp://192.168.68.10")
    sign_in("casa.exemplo.com")
    post "/configuracoes/aplicativos/ollama/conectar"
    expect(flash[:alert]).to include("IP deste servidor")
    post "/configuracoes/aplicativos/vaultwarden/conectar"
    expect(response).to redirect_to("/configuracoes/aplicativos/vaultwarden")
  end
end
