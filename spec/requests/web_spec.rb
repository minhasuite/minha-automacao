require "rails_helper"

RSpec.describe "Web (sessão em cookie)" do
  let(:user) { create(:user, email: "web@ex.com") }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  it "sem login vai para /entrar; com login abre Início, Notificações e Configurações" do
    user # instalação com alguém (sem ninguém, vai para a primeira configuração)
    get "/"
    expect(response).to redirect_to(%r{/entrar})
    get "/entrar"
    expect(response).to have_http_status(:ok)

    post "/entrar", params: { email: user.email, password: "errada00" }
    expect(response).to have_http_status(:unprocessable_content)
    sign_in
    expect(response).to redirect_to("/")
    Onboarding.finish!(user.tenant)
    %w[/ /notificacoes /configuracoes/paineis].each do |path|
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Minha Automação")
    end
    get "/entrar"
    expect(response).to redirect_to("/")
    delete "/sair"
    get "/"
    expect(response).to redirect_to(%r{/entrar})
  end

  it "cria conta" do
    get "/criar-conta"
    expect(response).to have_http_status(:ok)
    post "/criar-conta", params: { name: "Lia", email: "lia@ex.com", password: "12345678" }
    expect(response).to redirect_to("/")
    expect(User.find_by(email: "lia@ex.com").tenant.name).to eq("Casa de Lia")
    post "/criar-conta", params: { name: "Lia", email: "lia@ex.com", password: "1" }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "esqueci a senha sempre volta para /entrar" do
    get "/esqueci-a-senha"
    expect(response).to have_http_status(:ok)
    expect { post "/esqueci-a-senha", params: { email: user.email } }.to have_enqueued_mail(PasswordMailer, :reset)
    expect(response).to redirect_to("/entrar")
  end

  it "notificações: abrir marca como lida; marcar todas" do
    n1, n2 = within(user.tenant) { [ create(:notification, user: user), create(:notification) ] }
    sign_in
    patch "/notificacoes/#{n1.id}/lida"
    expect(n1.reload.read_at).to be_present
    patch "/notificacoes/todas-lidas"
    expect(n2.reload.read_at).to be_present
  end

  describe "configurações" do
    before { sign_in }

    it "abre cada seção, sem dados de empresa nem \"entrar em outra empresa\"" do
      get "/configuracoes"
      expect(response).to redirect_to("/configuracoes/paineis")
      %w[/configuracoes/paineis /configuracoes/pessoas /configuracoes/chaves /configuracoes/sistema /configuracoes/conta].each do |path|
        get path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("Empresa", "CNPJ", "Razão social", "outra empresa")
      end
    end

    it "atualiza a conta" do
      patch "/configuracoes/conta", params: { account: { name: "Outro", password: "novasenha1", current_password: "errada" } }
      expect(flash[:alert]).to eq("Senha atual incorreta.")
      patch "/configuracoes/conta", params: { account: { name: "Outro", password: "novasenha1", current_password: "12345678" } }
      expect(user.reload).to have_attributes(name: "Outro")
      expect(user.authenticate("novasenha1")).to be_truthy
      patch "/configuracoes/conta", params: { account: { name: "" } }
      expect(flash[:alert]).to be_present
    end

    it "exporta, zera e exclui a conta" do
      get "/configuracoes/exportar"
      expect(JSON.parse(response.body)["user"]["email"]).to eq(user.email)
      post "/configuracoes/zerar", params: { confirm: "nao" }
      expect(flash[:alert]).to include("ZERAR")
      post "/configuracoes/zerar", params: { confirm: "ZERAR" }
      expect(flash[:notice]).to eq("Dados da instalação apagados.")
      delete "/configuracoes/conta", params: { confirm: "nao" }
      expect(flash[:alert]).to include("EXCLUIR")
      tenant_id = user.tenant_id
      delete "/configuracoes/conta", params: { confirm: "EXCLUIR" }
      expect(Tenant.exists?(tenant_id)).to be false
    end

    it "membro não zera, não vê pessoas nem chaves" do
      member = create(:user, tenant: user.tenant, role: "member", email: "membro@ex.com")
      sign_in(member)
      post "/configuracoes/zerar", params: { confirm: "ZERAR" }
      expect(flash[:alert]).to eq("Só o dono pode fazer isso.")
      get "/configuracoes/pessoas"
      expect(response).to redirect_to("/")
      get "/configuracoes/chaves"
      expect(response).to redirect_to("/")
      get "/configuracoes/paineis"
      expect(response.body).not_to include("Pessoas")
    end
  end

  it "chaves de integração pela API (só o dono)" do
    site = within(user.tenant) { create(:site) }
    headers = auth_headers(user)
    post "/api/v1/api_keys", params: { name: "ERP", scopes: %w[read], site_ids: [ site.id ] }, headers: headers
    expect(response).to have_http_status(:created)
    key_id = data["id"]
    expect(data).to include("site_ids" => [ site.id ])
    expect(data["token"]).to start_with("svc_")
    get "/api/v1/me", headers: { "X-Api-Key" => data["token"] }
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/api_keys", params: { name: "x", scopes: %w[nada], site_ids: [ site.id ] }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    post "/api/v1/api_keys", params: { name: "x", scopes: %w[read] }, headers: headers
    expect(json.dig("error", "message")).to include("local")
    get "/api/v1/api_keys", headers: headers
    expect(data.size).to eq(1)
    get "/api/v1/api_keys", headers: auth_headers(create(:user, tenant: user.tenant, role: "admin"))
    expect(response).to have_http_status(:forbidden)
    delete "/api/v1/api_keys/#{key_id}", headers: headers
    expect(response).to have_http_status(:no_content)
  end
end
