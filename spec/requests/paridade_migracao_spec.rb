require "rails_helper"

# "Migre do HA em 10 minutos": assistente por cima do HomeAssistantImport,
# com um HA falso (fixture) no lugar do transporte (REST + WebSocket). Nunca
# fala com um HA de verdade.
RSpec.describe "Assistente Migre do HA" do
  include ActiveJob::TestHelper

  # HA falso: responde pelos caminhos REST e comandos WebSocket da fixture.
  class FakeHaTransport
    attr_reader :calls

    def initialize(fixture, fail_on: nil)
      @fx = fixture
      @fail_on = fail_on
      @calls = []
    end

    def get(path)
      @calls << path
      raise Integrations::Error, "HTTP 500" if path == @fail_on

      @fx["rest"].fetch(path) { raise Integrations::Error, "HTTP 404" }
    end

    def ws(type)
      @calls << type
      @fx["ws"].fetch(type)
    end
  end

  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa Teste") } }
  let(:fixture) { JSON.parse(Rails.root.join("spec/fixtures/files/ha_migracao.json").read) }
  let(:fake) { FakeHaTransport.new(fixture) }

  before do
    within(tenant) do
      create(:device, site: site, driver: "tuya_local", external_id: "dev1", name: "Ap local").tap do |d|
        create(:point, site: site, device: d, name: "Ap", key: "ap.ap", capability: "onoff", writable: true, address: { "dps" => "1" })
      end
    end
    allow(SafeHttp).to receive(:lookup).with("ha.teste").and_return([ "203.0.113.5" ])
    stub_request(:get, "http://ha.teste:8123/api/").to_return(status: 200, body: { message: "API running." }.to_json)
    allow(Integrations::HaMigration).to receive(:transport_for).and_return(fake)
    post("/entrar", params: { email: user.email, password: "12345678" })
  end

  def connect!
    post "/locais/#{site.id}/migrar-do-ha/conectar", params: { url: "http://ha.teste:8123/", token: "token-teste" }
    expect(response).to redirect_to("/locais/#{site.id}/migrar-do-ha")
    get "/locais/#{site.id}/migrar-do-ha"
    expect(response.body).to include("Lendo o Home Assistant", "data-controller=\"reload\"")
    perform_enqueued_jobs
  end

  def state = within(tenant) { Integrations::HaMigration.state(Integrations::HaMigration.integration(site)) }

  it "conecta, revisa, importa tudo em sombra e mostra o relatório" do
    get "/locais/#{site.id}/migrar-do-ha"
    expect(response.body).to include("Conecte o seu Home Assistant", "Token de acesso longo", "Tokens de acesso de longa duração")
    connect!
    integration = within(tenant) { Integrations::HaMigration.integration(site) }
    expect(integration.settings["url"]).to eq("http://ha.teste:8123")
    expect(integration.secrets["token"]).to eq("token-teste")
    expect(fake.calls).to include("/api/states", "config/device_registry/list", "/api/config/automation/config/100", "/api/config/script/config/apagar")

    get "/locais/#{site.id}/migrar-do-ha"
    body = response.body
    expect(body).to include("Revisar e escolher", "1/2", "aparelhos já", "Liga", "Sem par", "Apagar", "Noite", "1 temporizador", "1 liga/desliga", "ligada no HA")
    expect(body).to include("1 aparelho(s) do HA")
    expect(within(tenant) { site.automations.count }).to eq(0) # revisar não grava nada

    post "/locais/#{site.id}/migrar-do-ha/importar", params: { helpers: "1", automations: %w[100 200], scripts: %w[apagar], scenes: %w[1] }
    get "/locais/#{site.id}/migrar-do-ha"
    expect(response.body).to include("Importando", "role=\"progressbar\"")
    perform_enqueued_jobs

    expect(state["status"]).to eq("done")
    within(tenant) do
      expect(site.areas.pluck(:name)).to include("Sala", "Quarto")
      expect(site.automations.find_by!(name: "Liga")).to have_attributes(shadow: true, enabled: true)
      expect(site.scripts.find_by!(name: "Apagar")).to have_attributes(shadow: true)
      expect(site.scenes.find_by!(name: "Noite")).to have_attributes(shadow: true)
      expect(Command.count).to eq(0)
    end
    r = state["report"]
    expect(r["came"]).to include("areas" => 2, "helpers" => 2, "scenes" => 1, "automations" => 2, "scripts" => 1)
    expect(r["blueprints"].find { |b| b["name"] == "Liga" }).to include("lossless" => true, "enabled" => true)
    expect(r["blueprints"].find { |b| b["name"] == "Sem par" }["lossless"]).to be(false)
    expect(r["left_out"].pluck("what")).to include("Tomada do quarto", "Noite: switch.sumiu")

    get "/locais/#{site.id}/migrar-do-ha"
    expect(response.body).to include("Pronto! A casa do HA está aqui.", "Viraram blueprints", "Ficou de fora", "Tomada do quarto",
                                     "entidade da cena sem ponto equivalente", "modo sombra")
  end

  it "importa só o escolhido (sem helpers, uma automação) e anota o que ficou sem de-para" do
    connect!
    post "/locais/#{site.id}/migrar-do-ha/importar", params: { automations: %w[100] }
    perform_enqueued_jobs
    within(tenant) do
      expect(site.automations.pluck(:name)).to eq([ "Liga" ])
      expect(site.scripts.count).to eq(0)
      expect(site.scenes.count).to eq(0)
      expect(site.points.where.not(helper: nil).where(name: %w[Modo Rega])).to be_empty
    end
    liga = state["report"]["blueprints"].first
    expect(liga["notes"].join).to include("input_boolean.modo")
  end

  it "erro do HA vira mensagem e dá para recomeçar; endereço sem resposta volta ao formulário" do
    stub_request(:get, "http://ha.teste:8123/api/").to_return(status: 401)
    post "/locais/#{site.id}/migrar-do-ha/conectar", params: { url: "http://ha.teste:8123", token: "errado" }
    follow_redirect!
    expect(response.body).to include("O Home Assistant não respondeu", "token recusado")

    stub_request(:get, "http://ha.teste:8123/api/").to_return(status: 200, body: "{}")
    allow(Integrations::HaMigration).to receive(:transport_for).and_return(FakeHaTransport.new(fixture, fail_on: "/api/states"))
    connect!
    expect(state).to include("status" => "failed", "error" => "HTTP 500")
    get "/locais/#{site.id}/migrar-do-ha"
    expect(response.body).to include("HTTP 500", "Conectar e ler")
    post "/locais/#{site.id}/migrar-do-ha/recomecar"
    expect(state).to eq({})
  end

  it "transporte real: REST pelo SafeHttp e registros pelo WebSocket com o token" do
    plugin = Integrations::HomeAssistantPlugin
    integration = within(tenant) { plugin.new_integration(site, name: "HA", poll_s: 0).tap { |i| plugin.configure(i, { url: "http://ha.teste:8123", token: "tk" }) && i.save! } }
    msgs = [ { "type" => "auth_required" }, { "type" => "auth_ok" }, { "id" => 1, "type" => "result", "success" => true, "result" => [ { "id" => "sala" } ] } ]
    sent = []
    ws = double("ws")
    allow(ws).to receive(:read_json) { msgs.shift }
    allow(ws).to receive(:send_json) { |m| sent << m }
    allow(WsClient).to receive(:open).with("ws://ha.teste:8123/api/websocket", timeout: 15).and_yield(ws)
    t = within(tenant) { Integrations::HaMigration::Transport.new(integration) }
    expect(within(tenant) { t.ws("config/area_registry/list") }).to eq([ { "id" => "sala" } ])
    expect(sent).to eq([ { type: "auth", access_token: "tk" }, { id: 1, type: "config/area_registry/list" } ])
    stub_request(:get, "http://ha.teste:8123/api/states").to_return(body: "[]")
    expect(within(tenant) { t.get("/api/states") }).to eq([])

    msgs.replace([ { "type" => "auth_required" }, { "type" => "auth_invalid" } ])
    expect { within(tenant) { t.ws("config/area_registry/list") } }.to raise_error(Integrations::Error, "token recusado")
  end

  it "só técnico ou dono" do
    guest = create(:user, tenant: tenant, role: "member")
    within(tenant) { SiteMembership.create!(site: site, user: guest, role: "resident") }
    post("/entrar", params: { email: guest.email, password: "12345678" })
    get "/locais/#{site.id}/migrar-do-ha"
    expect(response).to have_http_status(:redirect)
    expect(flash[:alert]).to be_present
  end
end
