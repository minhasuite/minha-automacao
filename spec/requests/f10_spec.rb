require "rails_helper"

# F10: telas da sombra (linha do tempo, comparação, CSV, liga/desliga do
# local e da instalação, indicador no editor) e o assistente da integração
# Home Assistant (migração).
RSpec.describe "F10: telas da sombra" do
  let(:user) { create(:user, name: "Dona") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Local") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Aparelho", driver: "tuya_local") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, site: site, key: "ap.luz", name: "Luz", writable: true, value: false) } }
  let!(:automation) do
    within(tenant) do
      a = site.automations.create!(name: "Liga a luz", mode: "single", shadow: true)
      a.publish!({ "triggers" => [ { "type" => "manual" } ], "conditions" => [], "actions" => [ { "type" => "command", "point" => lamp.id, "command" => "on" } ] })
      a.update!(enabled: true)
      a
    end
  end

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  before { sign_in }

  it "executar uma automação em sombra não comanda e aparece na linha do tempo" do
    post "/automacoes/#{automation.id}/executar"
    within(tenant) { expect(Command.count).to eq(0) }
    get "/locais/#{site.id}/sombra"
    expect(response.body).to include("Teria feito: Ligar Luz", "Liga a luz", "1 em sombra", "0 ligada(s) fora da sombra")
    get "/locais/#{site.id}/sombra", params: { automacao: automation.id, tipo: "command", horas: "6" }
    expect(response.body).to include("Teria feito: Ligar Luz")
    get "/automacoes/#{automation.id}/editar"
    expect(response.body).to include("Em sombra", "Ver o que teria feito")
    get "/locais/#{site.id}/automacoes"
    expect(response.body).to include("Em sombra", "Pôr em sombra")
  end

  it "liga e desliga a sombra do local; lote tira e põe automação na sombra" do
    patch "/locais/#{site.id}/sombra", params: { shadow: "true" }
    expect(site.reload.shadow).to be(true)
    get "/locais/#{site.id}/sombra"
    expect(response.body).to include("Local em sombra", "Tirar o local da sombra")
    patch "/locais/#{site.id}/sombra", params: { shadow: "false" }
    expect(site.reload.shadow).to be(false)
    post "/locais/#{site.id}/automacoes/lote", params: { ids: [ automation.id ], op: "shadow_off" }
    expect(automation.reload.shadow).to be(false)
    patch "/automacoes/#{automation.id}", params: { automation: { shadow: "1" } }
    expect(automation.reload.shadow).to be(true)
  end

  it "comparar agora com uma fonte falsa, ver o relatório e baixar o CSV" do
    fake = Class.new(Integrations::Plugin) do
      describe key: "ref_falsa", title: "Referência falsa", icon: "link", description: "teste"
      def self.reference(_i, _f, _t, entries:) = entries || { "x.a" => { "name" => "A de lá", "runs" => 2, "effects" => [] } }
      def self.state_for(_c, _v) = "*"
    end
    stub_const("Integrations::RefFalsa", fake)
    stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[RefFalsa])
    within(tenant) do
      site.integrations.create!(driver: "ref_falsa", name: "Ref")
      ExternalRef.link!(site, "ref_falsa", "x.a", kind: "automation", target: automation)
    end
    post "/locais/#{site.id}/sombra/comparar", params: { fonte: "ref_falsa", horas: "24" }
    report = within(tenant) { ShadowReport.last }
    expect(response).to redirect_to("/locais/#{site.id}/sombra/relatorios/#{report.id}")
    follow_redirect!
    expect(response.body).to include("Liga a luz", "MA a menos", "disparos 2 na referência × 0 na sombra")
    get "/locais/#{site.id}/sombra/relatorios/#{report.id}", params: { status: "same" }
    expect(response.body).to include("Nada nessa situação")
    get "/locais/#{site.id}/sombra/relatorios/#{report.id}.csv"
    expect(response.body).to include("Automação;Referência;Status", "Liga a luz;x.a;MA a menos")
    get "/locais/#{site.id}/sombra"
    expect(response.body).to include("Comparar agora", "1 ma a menos", "ref_falsa")
    post "/locais/#{site.id}/sombra/comparar", params: { fonte: "nao_existe" }
    expect(flash[:alert]).to include("desconhecida")
  end

  it "sombra da instalação em Configurações → Sistema" do
    patch "/configuracoes/sistema", params: { shadow: "true" }
    expect(tenant.reload.settings["shadow"]).to be(true)
    get "/configuracoes/sistema"
    expect(response.body).to include("Modo sombra da instalação", "Desligar a sombra")
    get "/locais/#{site.id}/sombra"
    expect(response.body).to include("Local em sombra")
  end

  it "cena com a marca de sombra e o assistente do Home Assistant" do
    post "/locais/#{site.id}/cenas", params: { scene: { name: "Noite", shadow: "1", items: { "0" => { point_id: lamp.id, command: "off" } } } }
    scene = within(tenant) { site.scenes.find_by!(name: "Noite") }
    expect(scene.shadow).to be(true)
    post "/cenas/#{scene.id}/acionar"
    within(tenant) { expect(Command.count).to eq(0) }
    get "/locais/#{site.id}/integracoes/nova", params: { tipo: "home_assistant" }
    expect(response.body).to include("Token de acesso longo")
    within(tenant) { tenant.update!(http_allow_text: "192.168.0.10") }
    stub_request(:get, "http://192.168.0.10:8123/api/").with(headers: { "Authorization" => "Bearer tok" }).to_return(body: "{\"message\":\"API running.\"}")
    post "/locais/#{site.id}/integracoes", params: { tipo: "home_assistant", integration: { url: "http://192.168.0.10:8123/", token: "tok" } }
    integration = within(tenant) { site.integrations.find_by!(driver: "home_assistant") }
    expect(integration).to have_attributes(status: "ok", settings: hash_including("url" => "http://192.168.0.10:8123"))
    expect(integration.secrets["token"]).to eq("tok")
    stub_request(:get, "http://192.168.0.10:8123/api/").to_return(status: 401)
    expect(within(tenant) { Integrations::HomeAssistantPlugin.login(integration, { url: "", token: "" }) }.alert).to include("token recusado")
    post "/locais/#{site.id}/integracoes", params: { tipo: "home_assistant", integration: { url: "" } }
    expect(response.body).to include("Informe o endereço")
  end
end
