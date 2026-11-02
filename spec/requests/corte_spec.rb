require "rails_helper"

# Corte: tela de saúde (só administradores), papel Leitor (vê painéis, não
# comanda nem vê cadastro/configurações) e dados sensíveis ocultos para quem
# não é técnico/dono, na web e na API.
RSpec.describe "Corte: saúde, Leitor e dados sensíveis" do
  let(:owner) { create(:user, email: "teste-dono@ex.com") }
  let(:tenant) { owner.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Teste Casa") } }
  let!(:device) do
    within(tenant) do
      create(:device, site: site, name: "Teste Câmera", serial: "SN123", last_error: "timeout em 192.168.68.50:554",
                      address: { "host" => "192.168.68.50", "username" => "admin", "port" => 554, "mac" => "AA:BB:CC:DD:EE:FF" })
    end
  end
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Teste Luz", value: false, address: { "url" => "rtsp://admin:x@192.168.68.50/s1" }) } }

  def sign_in(u = owner) = post("/entrar", params: { email: u.email, password: "12345678" })
  def member(role, email) = create(:user, tenant: tenant, role: "member", email: email).tap { |u| within(tenant) { create(:site_membership, site: site, user: u, role: role) } }

  describe "saúde do sistema" do
    it "o administrador vê as verificações do registro; membro não vê nem o item do menu" do
      sign_in
      get "/configuracoes/saude"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Saúde do sistema", "Integrações", "Aparelhos e pontos", "Fila de tarefas", "Backup", "Disco",
                                       "Versão e tempo no ar", "Sombra", "Pronto para a troca", "Teste Casa: aparelhos sem sinal")
      get "/configuracoes/sistema"
      expect(response.body).to include("/configuracoes/saude")

      sign_in(member("resident", "teste-morador@ex.com"))
      get "/configuracoes/saude"
      expect(response).to have_http_status(:not_found)
      get "/configuracoes/sistema"
      expect(response.body).not_to include("/configuracoes/saude")
    end
  end

  describe "papel Leitor" do
    let!(:reader) { member("viewer", "teste-leitor@ex.com") }

    it "vê o painel do Início sem botão de comando; não comanda, não abre cadastro nem configurações" do
      sign_in(reader)
      get "/"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Teste Luz")
      expect(response.body).not_to include("Ligar Teste Luz", "/locais\"", "Perguntar à casa")
      expect(response.body).to include("Minha conta")

      post "/pontos/#{lamp.id}/comando", params: { command: "on" }
      expect(within(tenant) { Command.count }).to eq(0)

      get "/locais"
      expect(response).to redirect_to("/")
      get "/locais/#{site.id}"
      expect(flash[:alert]).to eq("Leitor só vê os painéis.")
      get "/dispositivos/#{device.id}"
      expect(flash[:alert]).to eq("Leitor só vê os painéis.")
      get "/locais/#{site.id}/automacoes"
      expect(flash[:alert]).to eq("Leitor só vê os painéis.")
      get "/pontos/#{lamp.id}"
      expect(response).to have_http_status(:ok)

      get "/configuracoes"
      expect(response).to redirect_to("/configuracoes/conta")
      %w[/configuracoes/paineis /configuracoes/sistema /configuracoes/exportar /configuracoes/saude].each do |path|
        get path
        expect(response).to have_http_status(:not_found), path
      end
      get "/configuracoes/conta"
      expect(response.body).not_to include("/configuracoes/paineis")
    end

    it "na API vê painéis e pontos (sem endereço sensível), mas não comanda nem lista dispositivos" do
      h = auth_headers(reader)
      get "/api/v1/sites/#{site.id}/dashboards", headers: h
      expect(response).to have_http_status(:ok)
      get "/api/v1/devices/#{device.id}/points", headers: h
      expect(response).to have_http_status(:ok)
      expect(data.first["address"]).to eq("url" => "oculto")
      get "/api/v1/devices/#{device.id}/points", params: { view: "app" }, headers: h
      expect(data.first["can_command"]).to be false
      post "/api/v1/points/#{lamp.id}/commands", params: { command: "on" }, headers: h
      expect(response).to have_http_status(:forbidden)
      get "/api/v1/sites/#{site.id}/devices", headers: h
      expect(response).to have_http_status(:forbidden)
    end

    it "aparece como papel nas pessoas e nos painéis, e o aviso 'Todos do local' inclui o Leitor" do
      expect(SiteMembership.role_label("viewer")).to eq("Leitor")
      expect(SiteMembership.allowed?("viewer", :view)).to be true
      expect(SiteMembership.allowed?("viewer", :command, risk: "normal")).to be false
      expect(within(tenant) { Notifier.recipients("role:viewer", site) }).to include(reader)
      expect(within(tenant) { Notifier.recipient_label("role:viewer", site) }).to eq("Todos do local, inclusive leitores")
      expect(reader.reload).to be_reader
      expect(owner).not_to be_reader
    end
  end

  describe "dados sensíveis" do
    it "técnico e dono veem IP, usuário e URL; morador vê 'oculto' na web e na API" do
      tech = member("technician", "teste-tecnico@ex.com")
      get "/api/v1/devices/#{device.id}", headers: auth_headers(tech)
      expect(data["address"]).to include("host" => "192.168.68.50", "username" => "admin")
      expect(data["serial"]).to eq("SN123")

      resident = member("resident", "teste-morador@ex.com")
      h = auth_headers(resident)
      get "/api/v1/devices/#{device.id}", headers: h
      expect(data["address"]).to eq("host" => "oculto", "username" => "oculto", "port" => 554, "mac" => "oculto")
      expect(data["serial"]).to eq("oculto")
      get "/api/v1/points/#{lamp.id}", headers: h
      expect(data["address"]).to eq("url" => "oculto")

      sign_in(resident)
      get "/dispositivos/#{device.id}"
      expect(response.body).not_to include("192.168.68.50")
      expect(response.body).to include("timeout em oculto")

      sign_in
      get "/dispositivos/#{device.id}"
      expect(response.body).to include("192.168.68.50")
    end

    it "mascara chaves e textos com IP, MAC e URL" do
      expect(Sensitive.mask({ "a" => [ { "token" => "x", "n" => 1 } ], "t" => "em 10.0.0.1:80 e aa-bb-cc-dd-ee-ff", "u" => "http://h/x" }))
        .to eq("a" => [ { "token" => "oculto", "n" => 1 } ], "t" => "em oculto e oculto", "u" => "oculto")
      expect(Sensitive.scrub(nil)).to eq("")
    end
  end
end
