require "rails_helper"

RSpec.describe "Auth e conta" do
  describe "POST /api/v1/auth/signup" do
    it "cria a instalação, o dono e os tokens" do
      post "/api/v1/auth/signup", params: { name: "Ana Souza", email: "ANA@ex.com", password: "12345678" }
      expect(response).to have_http_status(:created)
      expect(data).to include("token_type" => "Bearer")
      expect(data["user"]).to include("email" => "ana@ex.com", "role" => "owner")
      tenant = User.find_by(email: "ana@ex.com").tenant
      expect(tenant.name).to eq("Casa de Ana")
    end

    it "recusa senha curta e e-mail repetido" do
      create(:user, email: "ana@ex.com")
      post "/api/v1/auth/signup", params: { name: "Ana", email: "ana@ex.com", password: "123" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(json.dig("error", "code")).to eq("validation_failed")
    end
  end

  describe "login, refresh e logout" do
    let!(:user) { create(:user, email: "bia@ex.com") }

    it "membro faz login (sem empresa atual na requisição)" do
      create(:user, email: "rui@ex.com", role: "member", tenant: user.tenant)
      ActsAsTenant.current_tenant = nil
      post "/api/v1/auth/login", params: { email: "rui@ex.com", password: "12345678" }
      expect(response).to have_http_status(:created)
      expect(data["user"]).to include("role" => "member", "role_label" => "Membro")
    end

    it "faz login, rotaciona o refresh e detecta reuso" do
      post "/api/v1/auth/login", params: { email: "bia@ex.com", password: "12345678" }
      expect(response).to have_http_status(:created)
      first_refresh = data["refresh_token"]

      post "/api/v1/auth/refresh", params: { refresh_token: first_refresh }
      expect(response).to have_http_status(:ok)
      expect(data["refresh_token"]).not_to eq(first_refresh)

      post "/api/v1/auth/refresh", params: { refresh_token: first_refresh }
      expect(response).to have_http_status(:unauthorized)
      expect(json.dig("error", "code")).to eq("token_reuse_detected")
      expect(user.api_tokens.active.count).to eq(0)
    end

    it "recusa senha errada e refresh inválido" do
      post "/api/v1/auth/login", params: { email: "bia@ex.com", password: "errada00" }
      expect(response).to have_http_status(:unauthorized)
      post "/api/v1/auth/refresh", params: { refresh_token: "x" }
      expect(json.dig("error", "code")).to eq("invalid_token")
    end

    it "logout revoga o token" do
      headers = auth_headers(user)
      delete "/api/v1/auth/logout", headers: headers
      expect(response).to have_http_status(:no_content)
      get "/api/v1/me", headers: headers
      expect(response).to have_http_status(:unauthorized)
      expect(json.dig("error", "code")).to eq("unauthorized")
    end

    it "expira o access token em 30 minutos" do
      headers = auth_headers(user)
      travel 31.minutes do
        get "/api/v1/me", headers: headers
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "/api/v1/me" do
    let(:user) { create(:user) }
    let(:headers) { auth_headers(user) }

    it "mostra e atualiza o perfil (nome e senha)" do
      get "/api/v1/me", headers: headers
      expect(data).to include("id" => user.id, "has_password" => true)
      expect(data["company"]).to include("id" => user.tenant_id)
      expect(data["created_at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)

      patch "/api/v1/me", params: { name: "Novo Nome", password: "novasenha1", current_password: "12345678" }, headers: headers
      expect(data["name"]).to eq("Novo Nome")
      expect(user.reload.authenticate("novasenha1")).to be_truthy
    end

    it "exige a senha atual para trocar" do
      patch "/api/v1/me", params: { password: "novasenha1", current_password: "errada" }, headers: headers
      expect(json.dig("error", "code")).to eq("invalid_password")
    end

    it "exporta os dados da empresa" do
      within(user.tenant) { create(:notification, title: "Bem-vindo") }
      get "/api/v1/me/export", headers: headers
      expect(data["notifications"].first["title"]).to eq("Bem-vindo")
      expect(data["members"].first["email"]).to eq(user.email)
      expect(data["user"]["email"]).to eq(user.email)
    end

    it "zera a empresa preservando conta e cota de IA (só o dono)" do
      within(user.tenant) do
        create(:notification, title: "Algo")
        AiUsage.record!("ask")
      end
      member = create(:user, tenant: user.tenant, role: "member")
      post "/api/v1/me/wipe", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)

      post "/api/v1/me/wipe", headers: headers
      expect(data["deleted"]["notifications"]).to eq(1)
      within(user.tenant) do
        expect(Notification.count).to eq(0)
        expect(AiUsage.count).to eq(1)
      end
    end

    it "exclui a conta; último membro leva a empresa" do
      tenant = user.tenant
      delete "/api/v1/me", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(User.exists?(user.id)).to be false
      expect(Tenant.exists?(tenant.id)).to be false
    end

    it "exclui só o usuário quando há outro membro" do
      other = create(:user, tenant: user.tenant)
      delete "/api/v1/me", headers: headers
      expect(Tenant.exists?(user.tenant_id)).to be true
      expect(other.reload).to be_present
    end
  end

  describe "esqueci a senha" do
    let!(:user) { create(:user, email: "cris@ex.com") }

    it "sempre 200; manda o e-mail com link só para conta existente" do
      expect {
        post "/api/v1/auth/password/forgot", params: { email: "CRIS@ex.com" }
      }.to have_enqueued_mail(PasswordMailer, :reset)
      expect(data).to eq("sent" => true)
      expect {
        post "/api/v1/auth/password/forgot", params: { email: "ninguem@ex.com" }
      }.not_to have_enqueued_mail(PasswordMailer, :reset)
      expect(response).to have_http_status(:ok)
    end

    it "sem SMTP só registra no log e continua 200" do
      allow(ApplicationMailer).to receive(:deliverable?).and_return(false)
      expect { post "/api/v1/auth/password/forgot", params: { email: "cris@ex.com" } }.not_to have_enqueued_mail(PasswordMailer, :reset)
      expect(response).to have_http_status(:ok)
    end

    it "redefine com token de 30 min, uso único, e derruba as sessões" do
      headers = auth_headers(user)
      token = user.generate_token_for(:password_recovery)
      mail = PasswordMailer.reset(user, token)
      expect(mail.body.encoded).to include("/redefinir-senha?token=")

      post "/api/v1/auth/password/reset", params: { token: token, password: "novasenha123" }
      expect(data).to eq("reset" => true)
      expect(user.reload.authenticate("novasenha123")).to be_truthy
      get "/api/v1/me", headers: headers
      expect(response).to have_http_status(:unauthorized)

      post "/api/v1/auth/password/reset", params: { token: token, password: "outrasenha123" }
      expect(json.dig("error", "code")).to eq("invalid_token")

      expired = user.reload.generate_token_for(:password_recovery)
      travel 31.minutes do
        post "/api/v1/auth/password/reset", params: { token: expired, password: "outrasenha123" }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    it "página de redefinição abre" do
      get "/redefinir-senha", params: { token: "x" }
      expect(response.body).to include("Redefinir senha", "/api/v1/auth/password/reset")
    end
  end

  describe "sessões" do
    let!(:user) { create(:user) }

    it "lista e encerra as outras sessões" do
      _other, other_access, = ApiToken.issue(user, device_name: "Tablet")
      headers = auth_headers(user)
      get "/api/v1/me/sessions", headers: headers
      expect(data.size).to eq(2)
      expect(data.count { |s| s["current"] }).to eq(1)
      expect(response.body).not_to include("digest")

      delete "/api/v1/me/sessions", headers: headers
      expect(data).to eq("revoked" => 1)
      get "/api/v1/me", headers: { "Authorization" => "Bearer #{other_access}" }
      expect(response).to have_http_status(:unauthorized)
      get "/api/v1/me", headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "encerra uma sessão pelo id" do
      other, = ApiToken.issue(user)
      delete "/api/v1/me/sessions/#{other.id}", headers: auth_headers(user)
      expect(response).to have_http_status(:no_content)
      expect(other.reload.revoked_at).to be_present
    end
  end
end
