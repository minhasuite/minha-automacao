require "rails_helper"

# Produto: primeira configuração (Onboarding::STEPS) do zero até o painel,
# a descoberta de uma vez (mDNS/SSDP/plugins) e o registro de passos.
RSpec.describe "Primeira configuração" do
  before do
    allow(Mdns).to receive(:browse).and_return([])
    allow(Ssdp).to receive(:search).and_return([])
    allow(Broadlink).to receive(:discover).and_return([])
  end

  def step(key, **params) = post("/primeira-configuracao/#{key}", params: { onboarding: params })

  it "instalação nova: cria o dono, a casa com clima, adiciona o achado, áreas, tema, convite e conclui" do
    get "/"
    expect(response).to redirect_to("/primeira-configuracao")
    get "/entrar"
    expect(response).to redirect_to("/primeira-configuracao")
    get "/primeira-configuracao"
    expect(response.body).to include("Crie a conta do dono", "Passo 1 de 6", "oba", "Sua casa", "Família e app")

    step "account", name: "Teste Dono", email: "teste.dono@ex.com", password: "123"
    expect(response).to have_http_status(:unprocessable_content)
    step "account", name: "Teste Dono", email: "teste.dono@ex.com", password: "12345678"
    owner = User.find_by!(email: "teste.dono@ex.com")
    expect(owner).to be_owner
    expect(owner.tenant.name).to eq("Casa de Teste")
    expect(response).to redirect_to("/primeira-configuracao/home")

    get "/primeira-configuracao/home"
    expect(response.body).to include("Usar minha localização", "America/Sao_Paulo", "Ligar o clima")
    step "home", name: "Teste Casa", kind: "home", timezone: "America/Sao_Paulo", latitude: "-15.79", longitude: "-47.88", weather: "1"
    site = within(owner.tenant) { Site.find_by!(name: "Teste Casa") }
    expect(site.latitude.to_f).to eq(-15.79)
    weather = within(owner.tenant) { site.integrations.find_by!(driver: "weather") }
    expect(weather.status).to eq("syncing")
    expect(response).to redirect_to("/primeira-configuracao/discover")

    allow(Integrations::EsphomePlugin).to receive(:discover).and_return([ { "name" => "teste-sensor", "host" => "192.168.0.50", "port" => 6053, "txt" => { "friendly_name" => "Teste Sensor" } } ])
    allow(Ssdp).to receive(:search).with("urn:lge-com:service:webos-second-screen:1").and_return([ { "name" => "LG", "host" => "192.168.0.60", "port" => 3000, "txt" => {} } ])
    get "/primeira-configuracao/discover"
    expect(response.body).to include("ss-radar", "/primeira-configuracao/descobrir")
    get "/primeira-configuracao/descobrir"
    expect(response.body).to include("2 aparelhos encontrados", "Teste Sensor", "192.168.0.50:6053", "TV LG (webOS)")
    pick = { "plugin" => "esphome", "name" => "Teste Sensor", "host" => "192.168.0.50", "port" => 6053 }.to_json
    step "discover", pick: [ pick, "{lixo", { "plugin" => "nao_existe" }.to_json ]
    expect(flash[:notice]).to eq("1 aparelho adicionado: a leitura começa em instantes.")
    esp = within(owner.tenant) { site.integrations.find_by!(driver: "esphome") }
    expect(esp.settings).to include("host" => "192.168.0.50", "port" => 6053)
    get "/primeira-configuracao/descobrir"
    expect(response.body).to include("Já adicionado")

    lamp = within(owner.tenant) { create(:device, site: site, name: "Teste Lâmpada") }
    get "/primeira-configuracao/areas"
    expect(response.body).to include("Sala", "Cozinha", "Área externa", "Teste Lâmpada", "Sem área")
    step "areas", create: "1", suggested: %w[living kitchen nao_existe], custom: "Teste Lavanderia, "
    expect(response).to redirect_to("/primeira-configuracao/areas")
    expect(flash[:notice]).to eq("3 áreas criadas.")
    sala = within(owner.tenant) { site.areas.find_by!(name: "Sala") }
    get "/primeira-configuracao/areas"
    expect(response.body).to include("Teste Lavanderia", "ob-board", "draggable")
    step "areas", device_area: { lamp.id => sala.id }
    expect(lamp.reload.area_id).to eq(sala.id)
    expect(response).to redirect_to("/primeira-configuracao/dashboard")

    get "/primeira-configuracao/dashboard"
    expect(response.body).to include("Aurora", "Floresta", "Pronto com")
    step "dashboard", theme: "nao_existe"
    expect(response).to have_http_status(:unprocessable_content)
    step "dashboard", theme: "aurora"
    within(owner.tenant) do
      board = Dashboard.ensure_for(site).first
      expect(board).to be_auto
      expect(board.published["theme"]).to eq("key" => "aurora")
      expect(board.published["views"].first["title"]).to be_present
    end

    step "family", invite: "1"
    expect(response).to have_http_status(:ok)
    expect(response.body).to match(%r{/convite/[\w-]{20,}}).and include("<svg")
    expect(within(owner.tenant) { Invite.pending.count }).to eq(1)
    step "family"
    expect(response).to redirect_to("/")
    expect(flash[:notice]).to eq("Tudo pronto! Sua casa está no ar.")
    expect(Onboarding.pending?(owner.reload)).to be(false)
    get "/"
    expect(response.body).to include("ss-hero")
    get "/primeira-configuracao"
    expect(response).to have_http_status(:ok) # pode rever, mas o Início não volta para cá
  end

  it "quem cria conta na VPS vai para o assistente sem o passo de conta; membro e outros não" do
    post "/criar-conta", params: { name: "Teste Ana", email: "teste.ana@ex.com", password: "12345678" }
    get "/"
    expect(response).to redirect_to("/primeira-configuracao")
    get "/primeira-configuracao"
    expect(response.body).to include("Passo 1 de 5", "Sua casa")
    expect(response.body).not_to include("Crie a conta do dono")
    get "/primeira-configuracao/account"
    expect(response).to redirect_to("/primeira-configuracao")
    get "/primeira-configuracao/areas" # sem local ainda
    expect(response).to redirect_to("/primeira-configuracao")
    post "/primeira-configuracao/account", params: { onboarding: { name: "X", email: "x@ex.com", password: "12345678" } }
    expect(User.find_by(email: "x@ex.com")).to be_nil

    ana = User.find_by!(email: "teste.ana@ex.com")
    post "/primeira-configuracao/home/pular"
    expect(response).to redirect_to("/primeira-configuracao") # obrigatório
    member = create(:user, tenant: ana.tenant, role: "member", email: "teste.membro@ex.com")
    delete "/sair"
    post "/entrar", params: { email: member.email, password: "12345678" }
    get "/primeira-configuracao"
    expect(response).to redirect_to("/")
    delete "/sair"
    get "/primeira-configuracao"
    expect(response).to redirect_to("/entrar")
  end

  it "instalação que já tem local não abre o assistente sozinha" do
    owner = create(:user)
    within(owner.tenant) { create(:site) }
    post "/entrar", params: { email: owner.email, password: "12345678" }
    get "/"
    expect(response).to have_http_status(:ok)
  end

  it "passo novo entra só pelo registro (plugin falso)" do
    fake = Class.new(Onboarding::Step) do
      describe key: "teste_extra", icon: "star", art: "board"
      def self.partial = "web/onboarding/steps/account"
      def self.title = "Teste Extra"
      def self.save(ctx, params)
        return "Teste falhou" if params[:fail]

        ctx.site.update!(name: "Teste Extra Feito")
        nil
      end
    end
    stub_const("Onboarding::Steps::TesteExtraStep", fake)
    stub_const("Onboarding::STEPS", %w[HomeStep TesteExtraStep])

    owner = create(:user)
    site = within(owner.tenant) { create(:site) }
    Onboarding.update!(owner.tenant, done: %w[home], site_id: site.id)
    post "/entrar", params: { email: owner.email, password: "12345678" }
    get "/primeira-configuracao"
    expect(response.body).to include("Teste Extra", "Passo 2 de 2")
    post "/primeira-configuracao/teste_extra", params: { onboarding: { fail: "1" } }
    expect(response.body).to include("Teste falhou")
    post "/primeira-configuracao/teste_extra/pular"
    expect(response).to redirect_to("/")
    expect(Onboarding.state(owner.tenant.reload)["finished_at"]).to be_present
  end

  it "descoberta junta todos os plugins em paralelo; o que falha fica de fora" do
    owner = create(:user)
    site = within(owner.tenant) { create(:site) }
    allow(Integrations::ShellyPlugin).to receive(:discover).and_raise(Errno::EHOSTUNREACH)
    allow(Integrations::CastPlugin).to receive(:discover).and_return([ { "name" => "Teste Cast", "host" => "10.0.0.9", "port" => 8009, "txt" => { "fn" => "Sala TV" } } ])
    found = within(owner.tenant) { Onboarding::Discovery.call(site) }
    expect(found.map { |e| e.values_at("plugin", "name", "added") }).to eq([ [ "cast", "Sala TV", false ] ])
  end

  it "SSDP: monta o pedido e lê as respostas (um por IP)" do
    expect(Ssdp.request("urn:x")).to include("M-SEARCH * HTTP/1.1", "ST: urn:x", "MAN: \"ssdp:discover\"")
    ok = "HTTP/1.1 200 OK\r\nST: urn:x\r\nSERVER: WebOS/4.1 UPnP/1.0\r\nLOCATION: http://192.168.0.60:1754/\r\n\r\n"
    list = Ssdp.parse_all([ [ ok, "192.168.0.60" ], [ ok, "192.168.0.60" ], [ "NOTIFY * HTTP/1.1\r\n\r\n", "1.2.3.4" ] ])
    expect(list).to eq([ { "name" => "WebOS/4.1 UPnP/1.0", "host" => "192.168.0.60", "port" => 1754,
                           "txt" => { "st" => "urn:x", "server" => "WebOS/4.1 UPnP/1.0", "location" => "http://192.168.0.60:1754/" } } ])
    expect(Integrations::WebosPlugin.discovers?).to be(true)
  end
end
