require "rails_helper"

# ondaC1: telas dos protocolos (Gerenciar da integração, Z-Wave, Bluetooth,
# Matter/Thread, HomeKit, Google Home). Serviços de mentira; nada de rede.
RSpec.describe "Protocolos e ecossistemas (ondaC1)" do
  let(:user) { create(:user) }
  let!(:site) { within(user.tenant) { create(:site, name: "Casa") } }

  before { post("/entrar", params: { email: user.email, password: "12345678" }) }

  describe "tela Gerenciar (registro aberto)" do
    it "plugin falso com `panel?` ganha o botão, a tela genérica e as ações, sem mudar o núcleo" do
      fake = Class.new(Integrations::Plugin) do
        describe key: "teste_painel", title: "Teste Painel", icon: "chip", description: "Teste"
        texts en: { title: "Test Panel", description: "Test" }, es: { title: "Prueba Panel", description: "Prueba" }
        def self.panel? = true
        def self.panel_locals(_i, _p) = { stats: [ [ "Canal", "15" ] ], rows: [ [ "Rede", "Teste" ] ], actions: [ [ "ping", "Testar" ] ] }
        def self.panel_action(i, action, _p) = outcome(:panel, integration: i, notice: "feito #{action}")
      end
      stub_const("Integrations::TestePainelPlugin", fake)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[TestePainelPlugin])
      i = within(user.tenant) { site.integrations.create!(driver: "teste_painel", name: "Teste Painel") }

      get "/locais/#{site.id}/integracoes"
      expect(response.body).to include("/integracoes/#{i.id}/gerenciar", "Gerenciar")
      get "/integracoes/#{i.id}/gerenciar"
      expect(response.body).to include("Gerenciar Teste Painel", "Canal", "15", "Testar")
      post "/integracoes/#{i.id}/gerenciar/ping"
      expect(response).to redirect_to("/integracoes/#{i.id}/gerenciar")
      expect(flash[:notice]).to eq("feito ping")
    end

    it "integração sem tela Gerenciar dá 404" do
      i = within(user.tenant) { site.integrations.create!(driver: "mqtt", name: "MQTT") }
      get "/integracoes/#{i.id}/gerenciar"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "Z-Wave JS" do
    let(:ws) do
      FakeWs.new({ "type" => "version", "maxSchemaVersion" => 40, "serverVersion" => "3.0.0", "driverVersion" => "15.0.0" }) do |msg|
        result = case msg["command"]
        when "start_listening"
          { "state" => { "controller" => { "homeId" => 1, "sdkVersion" => "7.21" },
                         "nodes" => [ { "nodeId" => 1, "isControllerNode" => true, "status" => 4 },
                                      { "nodeId" => 4, "name" => "Teste Relé", "status" => 3, "isSecure" => true, "highestSecurityClass" => 0 } ] } }
        when "controller.get_node_neighbors" then { "neighbors" => [ 1 ] }
        else {}
        end
        { "type" => "result", "messageId" => msg["messageId"], "success" => true, "result" => result }
      end
    end
    let(:integration) { within(user.tenant) { site.integrations.create!(driver: "zwave_js", name: "Teste Z-Wave", settings: { "url" => "ws://10.0.0.9:3000" }) } }
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }

    before do
      allow(WsClient).to receive(:new).and_return(ws)
      allow(Rails).to receive(:cache).and_return(cache)
    end

    it "mostra rede, mapa e nós; pedir inclusão S2 liga o recarregar da tela; PIN da etapa DSK" do
      get "/integracoes/#{integration.id}/gerenciar"
      expect(response.body).to include("Mapa da rede", "Teste Relé", "Sem resposta", "S2 não autenticado", "Remover nó com falha", "<svg")
      post "/integracoes/#{integration.id}/gerenciar/include", params: { panel: { strategy: "s2" } }
      expect(ZwaveJs::Inclusion.get(integration.id)).to include("state" => "requested", "strategy" => "s2")
      get "/integracoes/#{integration.id}/gerenciar"
      expect(response.body).to include('data-controller="ss-reload"', "Esperando o aparelho")
      ZwaveJs::Inclusion.update(integration.id, state: "dsk", dsk: "11111-22222-33333-44444-55555-66666-77777-88888")
      get "/integracoes/#{integration.id}/gerenciar"
      expect(response.body).to include("22222-33333", "PIN (5 dígitos)")
      expect(response.body).not_to include("11111")
      post "/integracoes/#{integration.id}/gerenciar/pin", params: { panel: { pin: "abc" } }
      expect(flash[:alert]).to match(/5 dígitos/)
    end

    it "em inglês e espanhol" do
      user.update!(dashboard_prefs: user.dashboard_prefs.to_h.merge("locale" => "en"))
      get "/integracoes/#{integration.id}/gerenciar"
      expect(response.body).to include("Network map", "Add device", "Not responding")
      user.update!(dashboard_prefs: user.dashboard_prefs.to_h.merge("locale" => "es"))
      get "/integracoes/#{integration.id}/gerenciar"
      expect(response.body).to include("Mapa de la red", "Incluir aparato", "Sin respuesta")
    end
  end

  describe "Bluetooth do servidor" do
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Rails).to receive(:cache).and_return(cache) }

    it "assistente cria e abre Gerenciar; chave do serviço; o ble-scanner manda os anúncios pela API" do
      get "/locais/#{site.id}/integracoes/nova", params: { tipo: "bluetooth" }
      expect(response.body).to include("Chaves dos sensores cifrados", "ble-scanner")
      post "/locais/#{site.id}/integracoes", params: { tipo: "bluetooth", integration: { name: "Teste BT" } }
      i = within(user.tenant) { site.integrations.find_by!(driver: "bluetooth") }
      expect(response).to redirect_to("/integracoes/#{i.id}/gerenciar")
      post "/integracoes/#{i.id}/gerenciar/service_key"
      key = flash[:notice][/svc_\S+/]
      expect(key).to be_present

      data = Base64.strict_encode64([ 12, 0x09, *"Teste Termo".bytes ].pack("C*") + [ 7, 0x16, 0xD2, 0xFC, 0x40, 0x02, 0xCA, 0x09 ].pack("C*"))
      post "/api/v1/bluetooth/advertisements", params: { adapter: { name: "hci0" }, adverts: [ { mac: "A4:C1:38:00:00:09", rssi: -60, data: data } ] }.to_json,
                                               headers: { "X-Api-Key" => key, "Content-Type" => "application/json" }
      expect(response.parsed_body.dig("data", "understood")).to eq(1)
      get "/integracoes/#{i.id}/gerenciar"
      expect(response.body).to include("hci0", "Teste Termo", "Temperatura 25,06 °C")

      _, read_only = within(user.tenant) { ServiceApiKey.issue(user, name: "Teste", scopes: %w[read], site_ids: [ site.id ]) }
      post "/api/v1/bluetooth/advertisements", params: { adverts: [] }.to_json, headers: { "X-Api-Key" => read_only, "Content-Type" => "application/json" }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "Matter e Thread" do
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }
    let(:ws) do
      node = { "node_id" => 7, "available" => true, "attributes" => { "0/40/5" => "Teste Luz", "1/6/0" => true, "0/62/1" => [ { "2" => 24_582 } ] } }
      FakeWs.new({ "fabric_id" => 1, "sdk_version" => "2025.1", "bluetooth_enabled" => false }) do |msg|
        result = { "get_nodes" => [ node ], "open_commissioning_window" => { "setup_manual_code" => "34970112332", "setup_qr_code" => "MT:Y.K90AFN00KA0648G00" } }[msg["command"]]
        { "message_id" => msg["message_id"], "result" => result }
      end
    end

    before do
      allow(WsClient).to receive(:new).and_return(ws)
      allow(Rails).to receive(:cache).and_return(cache)
    end

    it "Gerenciar do Matter: servidor, aparelhos com quem compartilha e o QR do multi-admin" do
      i = within(user.tenant) { site.integrations.create!(driver: "matter", name: "Teste Matter", settings: { "url" => "ws://10.0.0.5:5580/ws" }) }
      get "/integracoes/#{i.id}/gerenciar"
      expect(response.body).to include("Teste Luz", "Google Home", "Comissionar", "O Matter Server está sem Bluetooth")
      post "/integracoes/#{i.id}/gerenciar/share", params: { panel: { node: "7" } }
      follow_redirect!
      expect(response.body).to include("Compartilhar Teste Luz", "3497-011-2332", "<svg")
    end

    it "Gerenciar do Thread: papel, rede e credenciais" do
      stub_request(:get, "http://10.0.0.6:8081/node").to_return(status: 200, body: { "State" => "leader", "NumOfRouter" => 1 }.to_json)
      stub_request(:get, "http://10.0.0.6:8081/node/dataset/active").to_return(status: 200, body: "")
      post "/locais/#{site.id}/integracoes", params: { tipo: "thread", integration: { url: "http://10.0.0.6:8081" } }
      i = within(user.tenant) { site.integrations.find_by!(driver: "thread") }
      follow_redirect!
      expect(response.body).to include("Líder", "Criar uma rede", "Importar dataset")
      user.update!(dashboard_prefs: user.dashboard_prefs.to_h.merge("locale" => "en"))
      get "/integracoes/#{i.id}/gerenciar"
      expect(response.body).to include("Leader", "Create a network")
    end
  end

  it "catálogo e formulário dos tipos novos nos três idiomas" do
    { "bluetooth" => "ble-scanner", "thread" => "8081", "google_home" => "Id do projeto no Google", "homekit_controller" => "Código HomeKit" }.each do |tipo, text|
      get "/locais/#{site.id}/integracoes/nova", params: { tipo: tipo }
      expect(response.body).to include(text)
    end
    user.update!(dashboard_prefs: user.dashboard_prefs.to_h.merge("locale" => "es"))
    get "/locais/#{site.id}/integracoes"
    expect(response.body).to include("Bluetooth (adaptador del servidor)", "HomeKit (aparatos)", "Google Home y Asistente de Google")
  end
end
