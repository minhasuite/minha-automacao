require "rails_helper"

# F8d: Configurações da instalação (pessoas, chaves de integração, painéis com
# visões) e o escopo de local/permissão da chave na API.
RSpec.describe "Configurações (F8d)" do
  let(:owner) { create(:user, email: "dono@ex.com") }
  let(:tenant) { owner.tenant }
  let!(:casa) { within(tenant) { create(:site, name: "Casa") } }
  let!(:loja) { within(tenant) { create(:site, name: "Loja") } }

  def sign_in(u = owner) = post("/entrar", params: { email: u.email, password: "12345678" })
  def role(site, user) = within(tenant) { site.role_for(user) }

  describe "pessoas" do
    before { sign_in }

    it "o dono cria a conta com senha inicial, ajusta papel e locais, desativa, reativa e remove" do
      get "/configuracoes/pessoas"
      expect(response.body).to include("Criar a conta", "Convidar por link", owner.email)

      post "/configuracoes/pessoas", params: { person: { name: "Rui", email: "rui@ex.com", password: "12345678", role: "member", site_id: casa.id, site_role: "resident" } }
      rui = User.find_by!(email: "rui@ex.com")
      expect(response).to redirect_to("/configuracoes/pessoas/#{rui.id}")
      expect(role(casa, rui)).to eq("resident")
      post "/configuracoes/pessoas", params: { person: { name: "X", email: "rui@ex.com", password: "12345678" } }
      expect(flash[:alert]).to be_present

      get "/configuracoes/pessoas/#{rui.id}"
      expect(response.body).to include("Papel em cada local", "Loja", "Desativar")
      patch "/configuracoes/pessoas/#{rui.id}/locais", params: { roles: { casa.id => "", loja.id => "operator" } }
      expect([ role(casa, rui), role(loja, rui) ]).to eq([ nil, "operator" ])
      patch "/configuracoes/pessoas/#{rui.id}/locais", params: { roles: { loja.id => "technician" } }
      expect(role(loja, rui)).to eq("technician")
      patch "/configuracoes/pessoas/#{rui.id}", params: { person: { role: "admin" } }
      expect(rui.reload.role).to eq("admin")

      _t, access, = ApiToken.issue(rui)
      post "/configuracoes/pessoas/#{rui.id}/ativar"
      expect(rui.reload).to be_disabled
      get "/api/v1/me", headers: { "Authorization" => "Bearer #{access}" }
      expect(response).to have_http_status(:unauthorized)
      post "/api/v1/auth/login", params: { email: "rui@ex.com", password: "12345678" }
      expect(response).to have_http_status(:unauthorized)
      post "/configuracoes/pessoas/#{rui.id}/ativar"
      expect(rui.reload).not_to be_disabled

      delete "/configuracoes/pessoas/#{rui.id}"
      expect(User.exists?(rui.id)).to be false
    end

    it "o dono não se altera; pessoa desativada não entra na web" do
      post "/configuracoes/pessoas/#{owner.id}/ativar"
      expect(flash[:alert]).to include("dono")
      delete "/configuracoes/pessoas/#{owner.id}"
      expect(User.exists?(owner.id)).to be true

      lia = create(:user, tenant: tenant, role: "member", email: "lia@ex.com")
      post "/configuracoes/pessoas/#{lia.id}/ativar"
      sign_in(lia)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "gera o link de convite (aparece uma vez) e cancela" do
      post "/configuracoes/pessoas/convite", params: { invite: { role: "member", site_id: loja.id, site_role: "guest" } }
      expect(response).to have_http_status(:ok)
      url = response.body[%r{http://[^"]+/convite/[\w-]+}]
      expect(url).to be_present
      invite = within(tenant) { Invite.pending.sole }
      expect(invite).to have_attributes(site_id: loja.id, site_role: "guest")
      get "/configuracoes/pessoas"
      expect(response.body).not_to include(url)
      expect(response.body).to include("Convites pendentes")
      delete "/configuracoes/convites/#{invite.id}"
      expect(within(tenant) { Invite.pending.count }).to eq(0)
      get URI(url).path
      expect(response).to have_http_status(:not_found)
    end

    it "administrador vê, mas não muda" do
      admin = create(:user, tenant: tenant, role: "admin", email: "adm@ex.com")
      sign_in(admin)
      get "/configuracoes/pessoas"
      expect(response.body).not_to include("Criar a conta")
      post "/configuracoes/pessoas/convite"
      expect(flash[:alert]).to include("dono")
    end
  end

  describe "chaves de integração (web)" do
    before { sign_in }

    it "cria com locais, permissões e validade; a chave aparece só na criação; revoga" do
      post "/configuracoes/chaves", params: { api_key: { name: "minhas-vendas", site_ids: [ casa.id ], scopes: %w[read write], validity: "90" } }
      plain = response.body[/svc_[\w-]+/]
      expect(plain).to be_present
      key = ServiceApiKey.sole
      expect(key).to have_attributes(site_ids: [ casa.id ], scopes: %w[read write])
      expect(key.expires_at).to be_within(1.minute).of(90.days.from_now)
      get "/configuracoes/chaves"
      expect(response.body).to include("minhas-vendas", "Casa", "Escrever valor em pontos", "Nunca")
      expect(response.body).not_to include(plain)

      post "/configuracoes/chaves", params: { api_key: { name: "sem local", scopes: %w[read], validity: "" } }
      expect(flash[:alert]).to include("local")

      delete "/configuracoes/chaves/#{key.id}"
      expect(key.reload.revoked_at).to be_present
      get "/api/v1/sites", headers: { "X-Api-Key" => plain }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "chave na API: escopo de local e de permissão" do
    let!(:device) { within(tenant) { create(:device, site: casa, name: "Etiqueta") } }
    let!(:price) { within(tenant) { create(:point, device: device, name: "Preço", capability: "measure", value: 10) } }
    let!(:other) { within(tenant) { create(:point, device: create(:device, site: loja), name: "Luz da loja", value: false) } }
    let(:tuya) { within(tenant) { create(:point, device: create(:device, site: casa, driver: "tuya_local"), name: "Tomada") } }

    def key(scopes) = { "X-Api-Key" => ServiceApiKey.issue(owner, name: "k", scopes: scopes, site_ids: [ casa.id ]).last }

    it "não vê nem mexe em outro local" do
      h = key(%w[read command write])
      get "/api/v1/sites", headers: h
      expect(data.map { |s| s["id"] }).to eq([ casa.id ])
      get "/api/v1/sites/#{loja.id}", headers: h
      expect(response).to have_http_status(:not_found)
      get "/api/v1/sites/#{loja.id}/devices", headers: h
      expect(response).to have_http_status(:not_found)
      get "/api/v1/points/#{other.id}", headers: h
      expect(response).to have_http_status(:not_found)
      post "/api/v1/points/#{other.id}/commands", params: { command: "turn_on" }, headers: h
      expect(response).to have_http_status(:not_found)
      post "/api/v1/points/#{other.id}/value", params: { value: "1" }, headers: h
      expect(response).to have_http_status(:not_found)

      get "/api/v1/sites/#{casa.id}/devices", headers: h
      expect(data.map { |d| d["name"] }).to include("Etiqueta")
      get "/api/v1/points/#{price.id}/history", headers: h
      expect(response).to have_http_status(:ok)
    end

    it "respeita a permissão: ler não comanda nem escreve; escrever grava no ponto virtual" do
      read = key(%w[read])
      get "/api/v1/points/#{price.id}", headers: read
      expect(response).to have_http_status(:ok)
      post "/api/v1/points/#{price.id}/value", params: { value: "12,5" }, headers: read
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/points/#{price.id}/commands", params: { command: "turn_on" }, headers: read
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/sites/#{casa.id}/devices", params: { name: "X" }, headers: read
      expect(response).to have_http_status(:forbidden)

      write = key(%w[write])
      get "/api/v1/points/#{price.id}", headers: write
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/points/#{price.id}/value", params: { value: "12,5" }, headers: write
      expect(data["value"]).to eq(12.5)
      expect(within(tenant) { price.reload.value }).to eq(12.5)
      post "/api/v1/points/#{tuya.id}/value", params: { value: "1" }, headers: write
      expect(json.dig("error", "code")).to eq("not_virtual")
      expect(ServiceApiKey.where.not(last_used_at: nil).count).to eq(2)
    end
  end

  describe "painéis em Configurações" do
    before { sign_in }

    it "lista com a coluna Local, ícone e menu lateral, visões com caminho, duplica e exclui" do
      get "/configuracoes/paineis"
      expect(response.body).to include("Casa", "Loja", "Novo painel")
      d = within(tenant) { Dashboard.find_by!(site: casa) }

      patch "/paineis/#{d.id}", params: { dashboard: { name: "Casa", icon: "sun", sidebar: "1" } }
      expect(d.reload).to have_attributes(icon: "sun", sidebar: true)
      get "/configuracoes/paineis"
      expect(response.body).to include(%(title="Casa"), "Sim")

      draft = { "schema_version" => 1, "views" => [ { "id" => "v1", "title" => "Início", "sections" => [] }, { "id" => "v2", "title" => "Cozinha", "sections" => [] } ] }
      within(tenant) { d.publish!(draft) }
      patch "/paineis/#{d.id}/rascunho", params: { op: "update_view", target: "v2", view_id: "v2", title: "Cozinha", icon: "light-bulb", path: "Cozinha Nova" }
      expect(d.reload.draft["views"].last).to include("path" => "cozinha-nova", "icon" => "light-bulb")
      patch "/paineis/#{d.id}/rascunho", params: { op: "move", kind: "view", target: "v2", dir: "up", view_id: "v2" }
      expect(d.reload.draft["views"].map { |v| v["id"] }).to eq(%w[v2 v1])
      post "/paineis/#{d.id}/publicar"
      get "/paineis/#{d.id}", params: { view: "cozinha-nova" }
      expect(response.body).to include("Visões do painel", "view=cozinha-nova", "Esta visão ainda está vazia")

      post "/paineis/#{d.id}/duplicar"
      copy = within(tenant) { Dashboard.find_by!(name: "Casa (cópia)") }
      expect(copy).to have_attributes(version: 1, sidebar: false, icon: "sun")
      expect(copy.definition["views"].map { |v| v["path"] }).to eq([ "cozinha-nova", nil ])

      delete "/paineis/#{copy.id}"
      expect(response).to redirect_to("/configuracoes/paineis")
    end

    it "caminho de visão inválido ou repetido não passa no esquema" do
      views = [ { "id" => "a", "title" => "A", "path" => "x", "sections" => [] }, { "id" => "b", "title" => "B", "path" => "x", "sections" => [] } ]
      expect(Dashboards::Schema.errors({ "schema_version" => 1, "views" => views })).to include(/caminho repetido/)
      views.last["path"] = "Com Espaço"
      expect(Dashboards::Schema.errors({ "schema_version" => 1, "views" => views })).to include(/caminho só com/)
    end

    it "painel no menu lateral só para quem o vê" do
      d = within(tenant) { Dashboard.ensure_for(casa).first.tap { |x| x.update!(sidebar: true, name: "Painel da Casa", roles: [ "resident" ]) } }
      get "/configuracoes/conta"
      expect(response.body).to include("Painel da Casa")
      guest = create(:user, tenant: tenant, role: "member", email: "g@ex.com")
      within(tenant) { create(:site_membership, site: casa, user: guest, role: "guest") }
      sign_in(guest)
      get "/configuracoes/conta"
      expect(response.body).not_to include("Painel da Casa")
      within(tenant) { d.update!(roles: []) }
      get "/configuracoes/conta"
      expect(response.body).to include("Painel da Casa")
    end
  end
end
