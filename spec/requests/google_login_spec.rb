require "rails_helper"

# Entrar com Google (web e app) com id_token assinado por chave de teste.
RSpec.describe "Entrar com Google" do
  def totp_now(secret) = Mfa::Totp.code(secret, Time.now.to_i / Mfa::Totp::STEP)

  def with_totp!(user)
    secret = Mfa::Totp.new_secret
    user.update!(otp_secret: secret, otp_enabled_at: Time.current)
    secret
  end

  describe "API" do
    it "sem client configurado: providers nulo e 503" do
      get "/api/v1/auth/providers"
      expect(data).to eq("google_client_id" => nil)
      post "/api/v1/auth/google", params: { id_token: "x" }
      expect(response).to have_http_status(:service_unavailable)
    end

    it "informa o client web, cria a conta (instalação nova, sem senha) e entra de novo pelo mesmo Google" do
      google_login_on!
      get "/api/v1/auth/providers"
      expect(data["google_client_id"]).to eq(GoogleIdTokenHelpers::GOOGLE_TEST_CLIENT)

      post "/api/v1/auth/google", params: { id_token: google_id_token, device_name: "Teste" }
      expect(response).to have_http_status(:created)
      user = User.find_by(email: "gil@ex.com")
      expect(user).to have_attributes(google_uid: "g-1", role: "owner", password_digest: nil)
      expect(user.tenant.name).to eq("Casa de Gil")
      expect(data["user"]).to include("google_linked" => true, "has_password" => false)

      expect { post "/api/v1/auth/google", params: { id_token: google_id_token(email: "outro@ex.com") } }.not_to change(User, :count)
      expect(response).to have_http_status(:created)
    end

    it "vincula a conta existente pelo e-mail verificado e pede o código das duas etapas" do
      google_login_on!
      user = create(:user, email: "gil@ex.com")
      secret = with_totp!(user)

      post "/api/v1/auth/google", params: { id_token: google_id_token }
      expect(json.dig("error", "code")).to eq("mfa_required")
      post "/api/v1/auth/google", params: { id_token: google_id_token, otp: "000000" }
      expect(json.dig("error", "code")).to eq("invalid_otp")
      post "/api/v1/auth/google", params: { id_token: google_id_token, otp: totp_now(secret) }
      expect(response).to have_http_status(:created)
      expect(user.reload.google_uid).to eq("g-1")
    end

    it "recusa token falso, vencido, de outra audiência, e-mail não verificado e e-mail de conta com outro Google" do
      google_login_on!
      create(:user, email: "ana@ex.com", google_uid: "g-ana")
      bad = [
        google_id_token(key: OpenSSL::PKey::RSA.generate(2048)),
        google_id_token(exp: 1.minute.ago),
        google_id_token(aud: "outro-client"),
        google_id_token(iss: "https://evil.example"),
        google_id_token(email_verified: false),
        google_id_token(sub: "g-intruso", email: "ana@ex.com"),
        "nao-e-jwt"
      ]
      bad.each do |token|
        post "/api/v1/auth/google", params: { id_token: token }
        expect(response).to have_http_status(:unauthorized), token
      end
      expect(User.where(email: "gil@ex.com")).to be_none
    end

    it "aceita as audiências extras configuradas" do
      google_login_on!(audiences: "client-ios, client-extra")
      post "/api/v1/auth/google", params: { id_token: google_id_token(aud: "client-extra") }
      expect(response).to have_http_status(:created)
    end

    it "com convite, a conta nasce na instalação do convite com o papel dele; conta desativada não entra" do
      google_login_on!
      owner = create(:user)
      _invite, token = within(owner.tenant) { Invite.generate!(created_by: owner, role: "member") }
      post "/api/v1/auth/google", params: { id_token: google_id_token, invite_token: token }
      expect(response).to have_http_status(:created)
      user = User.find_by(email: "gil@ex.com")
      expect(user).to have_attributes(tenant_id: owner.tenant_id, role: "member")
      expect(Invite.find_valid(token)).to be_nil

      user.disable!
      post "/api/v1/auth/google", params: { id_token: google_id_token }
      expect(response).to have_http_status(:forbidden)
    end

    it "vincula e desvincula em Segurança (não deixa ficar sem como entrar)" do
      google_login_on!
      user = create(:user)
      create(:user, google_uid: "g-outro")
      headers = auth_headers(user)

      post "/api/v1/me/google", params: { id_token: google_id_token(sub: "g-outro") }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      post "/api/v1/me/google", params: { id_token: google_id_token(email: "qualquer@gmail.com") }, headers: headers
      expect(data).to include("google_linked" => true)
      delete "/api/v1/me/google", headers: headers
      expect(data).to include("google_linked" => false)

      only_google = User.find_by!(google_uid: "g-outro")
      delete "/api/v1/me/google", headers: auth_headers(only_google.tap { _1.update_columns(password_digest: nil) })
      expect(json.dig("error", "code")).to eq("last_credential")
    end
  end

  describe "web" do
    it "o botão some sem client e em endereço que o Google não aceita (IP, .local)" do
      create(:user)
      get "/entrar"
      expect(response.body).not_to include('data-controller="google-signin"')

      google_login_on!
      get "/entrar"
      expect(response.body).to include('data-controller="google-signin"', GoogleIdTokenHelpers::GOOGLE_TEST_CLIENT)
      get "/criar-conta"
      expect(response.body).to include('data-google-signin-text-value="signup_with"')
      host! "192.168.68.199"
      get "/entrar"
      expect(response.body).not_to include("google-signin")
      host! "casa.local"
      get "/entrar"
      expect(response.body).not_to include("google-signin")
    end

    it "entra pelo botão, pedindo o código se a conta tem duas etapas" do
      google_login_on!
      user = create(:user, email: "gil@ex.com")
      post "/entrar/google", params: { credential: google_id_token, return_to: "/configuracoes/seguranca" }
      expect(response).to redirect_to("/configuracoes/seguranca")
      delete "/sair"

      secret = with_totp!(user)
      post "/entrar/google", params: { credential: google_id_token }
      expect(response).to redirect_to("/entrar/codigo")
      post "/entrar/codigo", params: { code: totp_now(secret) }
      expect(response).to redirect_to("/")

      delete "/sair"
      post "/entrar/google", params: { credential: google_id_token(email_verified: false) }
      expect(response).to redirect_to("/entrar")
      expect(flash[:alert]).to eq("Não foi possível entrar com o Google. Tente de novo.")
    end

    it "no convite, cria a conta na instalação do convite" do
      google_login_on!
      owner = create(:user)
      _invite, token = within(owner.tenant) { Invite.generate!(created_by: owner, role: "member") }
      get "/convite/#{token}"
      expect(response.body).to include('data-controller="google-signin"', %(name="invite" value="#{token}"))
      post "/entrar/google", params: { credential: google_id_token, invite: token }
      expect(User.find_by(email: "gil@ex.com")).to have_attributes(tenant_id: owner.tenant_id, role: "member")
    end

    it "na primeira configuração, o Google cria o dono" do
      google_login_on!
      get "/primeira-configuracao"
      follow_redirect! while response.redirect?
      expect(response.body).to include('data-controller="google-signin"')
      post "/entrar/google", params: { credential: google_id_token, return_to: "/primeira-configuracao" }
      expect(User.sole).to have_attributes(email: "gil@ex.com", role: "owner")
      expect(response).to redirect_to("/primeira-configuracao")
    end

    it "vincula e desvincula em Configurações → Segurança" do
      google_login_on!
      user = create(:user)
      post "/entrar", params: { email: user.email, password: "12345678" }
      get "/configuracoes/seguranca"
      expect(response.body).to include('data-security="google"', "Não vinculada", 'data-controller="google-signin"')

      post "/configuracoes/seguranca/google", params: { credential: google_id_token(email: "pessoal@gmail.com") }
      expect(flash[:notice]).to eq("Conta Google vinculada.")
      expect(user.reload.google_uid).to eq("g-1")
      get "/configuracoes/seguranca"
      expect(response.body).to include("Vinculada", "Desvincular")

      delete "/configuracoes/seguranca/google"
      expect(user.reload.google_uid).to be_nil
      post "/configuracoes/seguranca/google", params: { credential: "falso" }
      expect(flash[:alert]).to start_with("Não deu para vincular")
    end
  end
end
