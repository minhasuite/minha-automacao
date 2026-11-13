require "rails_helper"

# Pacote 3: telas (web) e API de pessoas/zonas, alarme, voz, pacotes e ferramentas.
RSpec.describe "Pacote 3: telas e API" do
  let(:user) { create(:user, role: "owner", name: "Ana Souza") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa", latitude: -15.8, longitude: -47.9) } }
  let!(:door) { within(tenant) { create(:point, site: site, device: create(:device, site: site, name: "Porta"), name: "Porta da frente", capability: "contact", value: false) } }
  let!(:lamp) { within(tenant) { create(:point, site: site, device: create(:device, site: site, name: "Sala"), name: "Luz", value: false) } }
  let(:member) { within(tenant) { create(:user, tenant: tenant, role: "member") } }
  let(:manifest) do
    { "format" => 1, "key" => "basico", "name" => "Pacote Básico", "version" => "1.0.0", "description" => "De teste",
      "items" => [ { "type" => "helper", "key" => "visitas", "name" => "Visitas", "helper" => "counter", "form" => { "initial" => "0" } } ] }
  end

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })
  def helper_point(name) = within(tenant) { site.points.helpers.find_by!(name: name) }

  describe "web" do
    before { sign_in }

    it "pessoas, zonas e alarme pelos helpers; painel com os widgets e o teclado" do
      %w[zone person alarm_panel].each do |tipo|
        get "/locais/#{site.id}/helpers/novo", params: { tipo: tipo }
        expect(response).to have_http_status(:ok)
      end
      post "/locais/#{site.id}/helpers", params: { tipo: "zone", helper: { name: "Trabalho", latitude: "-15,7", longitude: "-47,8", radius_m: "200" } }
      expect(response).to redirect_to("/locais/#{site.id}/helpers")
      phone = within(tenant) do
        Integrations::MobileAppPlugin.register!(site, user, install_id: "abcdefgh12", name: "Celular").tap do |d|
          Integrations::MobileAppPlugin.report!(d, "location" => { "latitude" => -15.8, "longitude" => -47.9 })
        end
      end
      gps = within(tenant) { phone.points.find_by!(device_class: "location") }
      get "/locais/#{site.id}/helpers/novo", params: { tipo: "person" }
      expect(response.body).to include("Presença · Celular (Localização (GPS) · confiança alta)")
      post "/locais/#{site.id}/helpers", params: { tipo: "person", helper: { name: "Ana", user_id: user.id, sources: [ gps.id, "" ], home_ssids: "Rede" } }
      expect(helper_point("Ana").value).to eq("Casa")
      post "/locais/#{site.id}/helpers", params: { tipo: "alarm_panel", helper: { name: "Alarme", code: "2468", trigger_time: "1m",
                                                                                  modes: { armed_away: { enabled: "1", sensors: [ door.id ], exit: "0s", entry: "0s" } } } }
      alarm = helper_point("Alarme")
      get "/locais/#{site.id}/helpers", params: { tipo: "alarm_panel" }
      expect(response.body).to include("Alarme", "modos: ausente (1)")
      get "/helpers/#{alarm.id}/editar"
      expect(response.body).to include("Código novo (vazio = manter)")
      expect(response.body).not_to include(alarm.address["code_digest"])

      dash = within(tenant) do
        site.dashboards.create!(name: "Segurança", definition: { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "Início", "sections" => [
                                  { "id" => "s", "widgets" => [ { "id" => "p1", "type" => "people" }, { "id" => "a1", "type" => "alarm", "bind" => alarm.id } ] }
                                ] } ] })
      end
      get "/paineis/#{dash.id}"
      expect(response.body).to include("Pessoas", "1 de 1 em casa", "Desarmado", "Ausente", %(name="command" value="arm_away"), "Falar com a casa")
      post "/pontos/#{alarm.id}/comando", params: { command: "arm_away", dashboard_id: dash.id, widget_id: "a1" }, headers: { "Turbo-Frame" => "w_a1" }
      expect(alarm.reload.value).to eq("armed_away")
      get "/paineis/#{dash.id}/w/a1"
      expect(response.body).to include("Armado (ausente)", "Desarmar", "data-controller=\"ss-code-keypad\"")
      post "/pontos/#{alarm.id}/comando", params: { command: "disarm", value: "0000" }
      expect(flash[:alert]).to eq("Código incorreto.")
      post "/pontos/#{alarm.id}/comando", params: { command: "disarm", value: "2468" }
      expect(alarm.reload.value).to eq("disarmed")
    end

    it "integrações: rastreador de rede e retenção da localização do app" do
      get "/locais/#{site.id}/integracoes/nova", params: { tipo: "network_tracker" }
      expect(response.body).to include("Endereços (um por linha", "Ping (ICMP)", "Conexão TCP (porta)")
      allow(Integrations::NetworkTrackerPlugin::Tcp).to receive(:up?).and_return(true)
      post "/locais/#{site.id}/integracoes", params: { tipo: "network_tracker", integration: { hosts: "Celular = 192.168.0.5", method: "tcp", port: "62078", consider_home: "5m" } }
      expect(flash[:notice]).to include("1 de 1 na rede")
      get "/locais/#{site.id}/integracoes/nova", params: { tipo: "mobile_app" }
      expect(response.body).to include("Guardar a localização exata por (horas)")
    end

    it "assistente: texto vira comando local e resposta em JSON" do
      post "/assistente", params: { site_id: site.id, text: "ligar a luz" }, as: :json
      expect(response.parsed_body).to include("text" => "Liguei Luz.", "intent" => "turn_on")
      post "/assistente", params: { site_id: site.id, text: "" }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      allow(Assist).to receive(:transcribe).and_return("desligar a luz")
      post "/assistente", params: { site_id: site.id, audio: Rack::Test::UploadedFile.new(StringIO.new("webm"), "audio/webm", original_filename: "fala.webm") }
      expect(response.parsed_body["text"]).to eq("Desliguei Luz.")
    end

    it "ferramentas: as quatro abas, definir helper, modelo ao vivo, ação e evento; membro não vê" do
      %w[estados modelo acao eventos].each do |aba|
        get "/locais/#{site.id}/ferramentas", params: { aba: aba, q: "luz" }
        expect(response).to have_http_status(:ok)
      end
      expect(response.body).to include("Escutando eventos", "turbo-cable-stream-source")
      within(tenant) { HelperTypes.save(HelperTypes.build(site, HelperTypes::Counter), "name" => "Visitas") }
      counter = helper_point("Visitas")
      post "/locais/#{site.id}/ferramentas/estado", params: { point_id: counter.id, value: "5" }
      expect(counter.reload.value).to eq(5)
      post "/locais/#{site.id}/ferramentas/estado", params: { point_id: lamp.id, value: "true" }
      expect(flash[:alert]).to include("Só helper")
      post "/locais/#{site.id}/ferramentas/modelo", params: { template: "{{ 2 | times: 4 }}" }, headers: { "Turbo-Frame" => "dev-result" }
      expect(response.body).to include("dev-result", "8")
      post "/locais/#{site.id}/ferramentas/modelo", params: { template: "1 +", mode: "expr" }
      expect(response.body).to include('data-tone="danger"')
      post "/locais/#{site.id}/ferramentas/acao", params: { point_id: lamp.id, command: "on" }
      expect(lamp.reload.value).to be true
      post "/locais/#{site.id}/ferramentas/acao", params: { point_id: lamp.id, command: "voar" }
      expect(flash[:alert]).to include("voar")
      post "/locais/#{site.id}/ferramentas/evento", params: { event: "teste.ola", data: "{}" }
      expect(flash[:notice]).to eq("Evento teste.ola disparado.")
      post "/locais/#{site.id}/ferramentas/evento", params: { event: "system_started" }
      expect(flash[:alert]).to include("sistema")

      within(tenant) { create(:site_membership, site: site, user: member, role: "owner") }
      sign_in(member)
      get "/locais/#{site.id}/ferramentas"
      expect(response).to have_http_status(:not_found)
      get "/locais/#{site.id}/helpers"
      expect(response.body).not_to include("Ferramentas")
    end

    it "pacotes: pré-visualiza, instala, mostra, procura versão nova e remove" do
      stub_request(:get, "https://raw.githubusercontent.com/dono/repo/HEAD/minha-automacao.json").to_return(body: manifest.to_json)
      get "/locais/#{site.id}/pacotes"
      expect(response.body).to include("Nenhum pacote instalado", "Ver o que entra")
      post "/locais/#{site.id}/pacotes/previa", params: { url: "https://github.com/dono/repo" }
      expect(response.body).to include("Pacote Básico", "Visitas", "Entra", "Instalar")
      post "/locais/#{site.id}/pacotes/instalar", params: { url: "https://github.com/dono/repo" }
      package = within(tenant) { site.packages.find_by!(key: "basico") }
      expect(response).to redirect_to("/pacotes/#{package.id}")
      follow_redirect!
      expect(response.body).to include("Pacote Básico", "Helper", "Abrir")
      get "/pacotes/#{package.id}/verificar"
      expect(response.body).to include("Você já está na versão mais nova", "Atualiza")
      post "/locais/#{site.id}/pacotes/previa", params: { url: "ftp://nada" }
      expect(flash[:alert]).to include("não reconhecido")
      delete "/pacotes/#{package.id}"
      expect(within(tenant) { site.points.helpers.where(name: "Visitas").count }).to eq(0)
    end
  end

  describe "API" do
    let(:headers) { auth_headers(user) }

    it "pessoas com as zonas (sem coordenadas) e o painel de alarme sem o hash do código" do
      within(tenant) do
        phone = Integrations::MobileAppPlugin.register!(site, user, install_id: "abcdefgh12", name: "Celular")
        Integrations::MobileAppPlugin.report!(phone, "location" => { "latitude" => -15.8, "longitude" => -47.9 })
        HelperTypes.save(HelperTypes.build(site, HelperTypes::Person), "name" => "Ana", "sources" => [ phone.points.first.id ])
        HelperTypes.save(HelperTypes.build(site, HelperTypes::AlarmPanel), "name" => "Alarme", "code" => "1234", "modes" => { "armed_home" => { "enabled" => "1" } })
      end
      get "/api/v1/sites/#{site.id}/people", headers: headers
      expect(data.first).to include("name" => "Ana", "zone" => "Casa", "home" => true)
      expect(json["meta"]["zones"].first).to include("name" => "Casa", "home" => true, "count" => 1)
      expect(response.body).not_to include("latitude")
      alarm = helper_point("Alarme")
      get "/api/v1/points/#{alarm.id}", headers: headers
      expect(data["address"]).to include("has_code" => true)
      expect(data["address"]).not_to have_key("code_digest")
      post "/api/v1/points/#{alarm.id}/commands", params: { command: "arm_home", value: nil }, headers: headers, as: :json
      expect(alarm.reload.value).to eq("armed_home")
      post "/api/v1/points/#{alarm.id}/commands", params: { command: "disarm", value: "1111" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "assistente por texto e erros" do
      post "/api/v1/sites/#{site.id}/assist", params: { text: "ligar a luz" }, headers: headers, as: :json
      expect(data).to include("intent" => "turn_on", "points" => [ lamp.id ])
      post "/api/v1/sites/#{site.id}/assist", params: { text: "" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      allow(Assist).to receive(:transcribe).and_raise(Ai::Client::Error, "sem stt")
      post "/api/v1/sites/#{site.id}/assist", params: { audio: Rack::Test::UploadedFile.new(StringIO.new("x"), "audio/webm", original_filename: "a.webm") }, headers: headers
      expect(json["error"]["code"]).to eq("ai_unavailable")
    end

    it "pacotes: pré-visualizar, instalar, listar, ver, atualizar e remover" do
      stub_request(:get, "https://exemplo.com/pacote.json").to_return(body: manifest.to_json)
      post "/api/v1/sites/#{site.id}/packages/preview", params: { url: "https://exemplo.com/pacote.json" }, headers: headers, as: :json
      expect(data).to include("errors" => [], "installed_version" => nil)
      expect(data["plan"].first).to include("type" => "helper", "action" => "add")
      post "/api/v1/sites/#{site.id}/packages", params: { url: "https://exemplo.com/pacote.json" }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      id = data["id"]
      get "/api/v1/sites/#{site.id}/packages", headers: headers
      expect(data.first).to include("key" => "basico", "items" => 1)
      get "/api/v1/packages/#{id}", headers: headers
      expect(data["installed"].first).to include("type" => "helper", "key" => "visitas")
      patch "/api/v1/packages/#{id}", headers: headers
      expect(response).to have_http_status(:ok)
      post "/api/v1/sites/#{site.id}/packages", params: { url: "https://nada" }, headers: headers, as: :json
      expect(json["error"]["code"]).to eq("invalid_package")
      delete "/api/v1/packages/#{id}", headers: headers
      expect(response).to have_http_status(:no_content)
    end

    it "ferramentas: estados, definir helper, modelo e evento; só administrador" do
      within(tenant) { HelperTypes.save(HelperTypes.build(site, HelperTypes::Counter), "name" => "Visitas") }
      counter = helper_point("Visitas")
      get "/api/v1/sites/#{site.id}/dev/states", params: { q: "luz" }, headers: headers
      expect(data.map { |s| s["id"] }).to eq([ lamp.id ])
      post "/api/v1/sites/#{site.id}/dev/states/#{counter.id}", params: { value: "3" }, headers: headers, as: :json
      expect(data["value"]).to eq(3)
      post "/api/v1/sites/#{site.id}/dev/states/#{lamp.id}", params: { value: "true" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      post "/api/v1/sites/#{site.id}/dev/template", params: { template: "{{ 1 | plus: 1 }}" }, headers: headers, as: :json
      expect(data["result"]).to eq("2")
      post "/api/v1/sites/#{site.id}/dev/template", params: { template: "1 +", mode: "expr" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      post "/api/v1/sites/#{site.id}/dev/events", params: { event: "teste.api", data: { "n" => 1 } }, headers: headers, as: :json
      expect(data["event"]).to eq("teste.api")
      post "/api/v1/sites/#{site.id}/dev/events", params: { event: "system_started" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      within(tenant) { create(:site_membership, site: site, user: member, role: "owner") }
      get "/api/v1/sites/#{site.id}/dev/states", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
