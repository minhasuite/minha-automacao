require "rails_helper"

RSpec.describe "Web (sessão em cookie)" do
  let(:user) { create(:user, email: "web@ex.com") }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  it "sem login vai para /entrar; com login abre Início, Notificações e Configurações" do
    get "/"
    expect(response).to redirect_to(%r{/entrar})
    get "/entrar"
    expect(response).to have_http_status(:ok)

    post "/entrar", params: { email: user.email, password: "errada00" }
    expect(response).to have_http_status(:unprocessable_content)
    sign_in
    expect(response).to redirect_to("/")
    %w[/ /notificacoes /configuracoes].each do |path|
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
    post "/criar-conta", params: { name: "Lia", email: "lia@ex.com", password: "12345678", company_name: "Casa da Lia" }
    expect(response).to redirect_to("/")
    expect(User.find_by(email: "lia@ex.com").tenant.name).to eq("Casa da Lia")
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

    it "atualiza empresa e conta" do
      patch "/configuracoes/empresa", params: { company: { trade_name: "Casa Nova", uf: "sp" } }
      expect(user.tenant.reload).to have_attributes(trade_name: "Casa Nova", uf: "SP")
      patch "/configuracoes/conta", params: { account: { name: "Outro", password: "novasenha1", current_password: "errada" } }
      expect(flash[:alert]).to eq("Senha atual incorreta.")
      patch "/configuracoes/conta", params: { account: { name: "Outro", password: "novasenha1", current_password: "12345678" } }
      expect(user.reload).to have_attributes(name: "Outro")
      expect(user.authenticate("novasenha1")).to be_truthy
      patch "/configuracoes/empresa", params: { company: { name: "" } }
      expect(flash[:alert]).to be_present
    end

    it "gera convite e entra em outra empresa pelo código" do
      post "/configuracoes/convite", params: { role: "admin" }
      code = flash[:notice][/\b[A-Z2-9]{10}\b/]
      expect(code).to be_present
      other = create(:user, email: "outro@ex.com")
      sign_in(other)
      post "/configuracoes/entrar-em-empresa", params: { code: "ERRADO" }
      expect(flash[:alert]).to eq("Código inválido ou vencido.")
      post "/configuracoes/entrar-em-empresa", params: { code: code }
      expect(other.reload).to have_attributes(tenant_id: user.tenant_id, role: "admin")
    end

    it "exporta, zera e exclui a conta" do
      get "/configuracoes/exportar"
      expect(JSON.parse(response.body)["user"]["email"]).to eq(user.email)
      post "/configuracoes/zerar", params: { confirm: "nao" }
      expect(flash[:alert]).to include("ZERAR")
      post "/configuracoes/zerar", params: { confirm: "ZERAR" }
      expect(flash[:notice]).to eq("Dados da empresa apagados.")
      delete "/configuracoes/conta", params: { confirm: "nao" }
      expect(flash[:alert]).to include("EXCLUIR")
      tenant_id = user.tenant_id
      delete "/configuracoes/conta", params: { confirm: "EXCLUIR" }
      expect(Tenant.exists?(tenant_id)).to be false
    end

    it "membro não muda a empresa nem convida" do
      member = create(:user, tenant: user.tenant, role: "member", email: "membro@ex.com")
      sign_in(member)
      patch "/configuracoes/empresa", params: { company: { trade_name: "X" } }
      expect(flash[:alert]).to eq("Só o dono da empresa pode fazer isso.")
      post "/configuracoes/convite"
      expect(flash[:alert]).to include("administrador")
    end
  end

  it "chaves de integração pela API (só o dono)" do
    headers = auth_headers(user)
    post "/api/v1/api_keys", params: { name: "ERP", scopes: %w[read] }, headers: headers
    expect(response).to have_http_status(:created)
    key_id = data["id"]
    expect(data["token"]).to start_with("svc_")
    get "/api/v1/me", headers: { "X-Api-Key" => data["token"] }
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/api_keys", params: { name: "x", scopes: %w[nada] }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    get "/api/v1/api_keys", headers: headers
    expect(data.size).to eq(1)
    get "/api/v1/api_keys", headers: auth_headers(create(:user, tenant: user.tenant, role: "admin"))
    expect(response).to have_http_status(:forbidden)
    delete "/api/v1/api_keys/#{key_id}", headers: headers
    expect(response).to have_http_status(:no_content)
  end
end
