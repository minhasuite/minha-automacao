require "rails_helper"

# ondaC1 (C6): Google Home cloud-to-cloud com um "Google de mentira": o
# account linking passa pelo /oauth/autorizar e /oauth/token de verdade, as
# intenções são as dos exemplos da documentação do Google e o HomeGraph é
# WebMock (conta de serviço gerada no teste). Nenhum projeto real.
RSpec.describe "Google Home (ondaC1, C6)" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:device) { within(tenant) { create(:device, site: site, name: "Sala", driver: "virtual") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Luz da sala", value: false, writable: true, expose: { "google" => true }) } }
  let!(:dimmer) { within(tenant) { create(:point, device: device, name: "Brilho", capability: "dimmer", min: 0, max: 255, value: 128, writable: true, expose: { "google" => true }) } }
  let!(:temp) { within(tenant) { create(:point, device: device, name: "Temperatura", capability: "measure", device_class: "temperature", value: 24.5, expose: { "google" => true }) } }
  let!(:gate) do
    within(tenant) { create(:point, device: device, name: "Portão", capability: "gate", value: "closed", options: %w[open closed], risk: "critical", writable: true, expose: { "google" => true }) }
  end
  let!(:hidden) { within(tenant) { create(:point, device: device, name: "Sirene", value: false, writable: true) } }
  let(:project) { "minha-casa-teste" }
  let(:redirect) { "https://oauth-redirect.googleusercontent.com/r/#{project}" }
  let(:rsa) { OpenSSL::PKey::RSA.new(2048) }
  let(:integration) do
    within(tenant) do
      o = Integrations::GoogleHomePlugin.setup(site, ActionController::Parameters.new(project_id: project))
      o.integration
    end
  end

  def sign_in = post("/entrar", params: { email: user.email, password: "12345678" })

  # Faz o account linking como o Google faz → access token.
  def link!
    secret = within(tenant) { integration.plugin.panel_action(integration, "secret", ActionController::Parameters.new).notice[/: (\S+)\z/, 1] }
    client = integration.reload.settings["client_id"]
    sign_in
    get "/oauth/autorizar", params: { client_id: client, redirect_uri: redirect, state: "xyz", response_type: "code" }
    expect(response.body).to include("Vincular o Google Home", "Casa")
    post "/oauth/autorizar", params: { client_id: client, redirect_uri: redirect, state: "xyz", response_type: "code", site_id: site.id }
    code = Rack::Utils.parse_query(URI(response.location).query)["code"]
    expect(response.location).to start_with(redirect).and include("state=xyz")
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: redirect, client_id: client, client_secret: secret }
    expect(response).to have_http_status(:ok)
    response.parsed_body["access_token"]
  end

  def google(token, intent, payload = nil)
    body = { requestId: "req-1", inputs: [ { intent: "action.devices.#{intent}", payload: payload }.compact ] }
    post "/google/smart_home", params: body.to_json, headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    response.parsed_body
  end

  it "account linking pelo OAuth comum, SYNC só do exposto, QUERY e DISCONNECT" do
    token = link!
    sync = google(token, "SYNC")
    devices = sync.dig("payload", "devices").index_by { |d| d["name"]["name"] }
    expect(devices.keys).to contain_exactly("Luz da sala", "Brilho", "Temperatura", "Portão")
    expect(devices["Luz da sala"]).to include("type" => "action.devices.types.LIGHT", "traits" => [ "action.devices.traits.OnOff" ])
    expect(devices["Portão"]).to include("type" => "action.devices.types.GARAGE", "traits" => [ "action.devices.traits.OpenClose" ])
    expect(devices["Temperatura"]["attributes"]).to include("queryOnlyTemperatureControl" => true)
    expect(sync.dig("payload", "agentUserId")).to eq("#{site.id}:#{user.id}")

    q = google(token, "QUERY", { devices: [ { id: dimmer.id }, { id: temp.id }, { id: hidden.id } ] })
    expect(q.dig("payload", "devices", dimmer.id)).to include("brightness" => 50, "status" => "SUCCESS", "online" => true)
    expect(q.dig("payload", "devices", temp.id)).to include("temperatureAmbientCelsius" => 24.5)
    expect(q.dig("payload", "devices", hidden.id)).to include("errorCode" => "deviceNotFound")

    google(token, "DISCONNECT")
    post "/google/smart_home", params: {}.to_json, headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "EXECUTE liga a luz, ajusta o brilho e o portão pede a confirmação do próprio Google" do
    token = link!
    ex = ->(id, command, params, challenge = nil) { { commands: [ { devices: [ { id: id } ], execution: [ { command: "action.devices.commands.#{command}", params: params, challenge: challenge }.compact ] } ] } }
    r = google(token, "EXECUTE", ex.call(lamp.id, "OnOff", { on: true }))
    expect(r.dig("payload", "commands", 0)).to include("status" => "SUCCESS", "states" => include("on" => true))
    expect(lamp.reload.value).to be true
    google(token, "EXECUTE", ex.call(dimmer.id, "BrightnessAbsolute", { brightness: 100 }))
    expect(dimmer.reload.value).to eq(255)

    r = google(token, "EXECUTE", ex.call(gate.id, "OpenClose", { openPercent: 100 }))
    expect(r.dig("payload", "commands", 0)).to include("status" => "ERROR", "errorCode" => "challengeNeeded", "challengeNeeded" => { "type" => "ackNeeded" })
    expect(gate.reload.value).to eq("closed")
    r = google(token, "EXECUTE", ex.call(gate.id, "OpenClose", { openPercent: 100 }, { ack: true }))
    expect(r.dig("payload", "commands", 0)["status"]).to eq("SUCCESS")
    expect(within(tenant) { Command.where(point: gate, source: "google").count }).to eq(1)
  end

  it "Report State e Request Sync pelo HomeGraph com a conta de serviço (WebMock)" do
    account = { type: "service_account", project_id: project, client_email: "teste@#{project}.iam.gserviceaccount.com", private_key: rsa.to_pem }.to_json
    within(tenant) { integration.plugin.login(integration, ActionController::Parameters.new(service_account: account)) }
    token_req = stub_request(:post, GoogleHome::HomeGraph::TOKEN_URL).with { |r| r.body.include?("jwt-bearer") }.to_return(status: 200, body: { access_token: "ya29.teste" }.to_json)
    report = stub_request(:post, "#{GoogleHome::HomeGraph::API}:reportStateAndNotification").with(headers: { "Authorization" => "Bearer ya29.teste" }).to_return(status: 200, body: "{}")
    sync = stub_request(:post, "#{GoogleHome::HomeGraph::API}:requestSync").to_return(status: 200, body: "{}")
    link!
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

    within(tenant) do
      expect(StateReport.reporters.find { |r| r.wants?(lamp.reload) }).to eq(GoogleHome::Reporter)
      expect(GoogleHome::Reporter.wants?(hidden)).to be false
      StateReportJob.perform_now(lamp.id, [ "GoogleHome::Reporter" ])
    end
    expect(token_req).to have_been_requested.once
    expect(report).to have_been_requested
    expect(a_request(:post, "#{GoogleHome::HomeGraph::API}:reportStateAndNotification").with { |r| JSON.parse(r.body).dig("payload", "devices", "states", lamp.id) == { "online" => true, "on" => false } }).to have_been_requested

    get "/integracoes/#{integration.id}/gerenciar"
    expect(response.body).to include("Ligar ao Google Home", "/google/smart_home", "oauth-redirect.googleusercontent.com/r/#{project}")
    post "/integracoes/#{integration.id}/gerenciar/sync"
    expect(sync).to have_been_requested
  end

  it "conta de serviço errada, projeto inválido e o portão só entra na tela Expor com confirmação" do
    within(tenant) do
      bad = Integrations::GoogleHomePlugin.setup(site, ActionController::Parameters.new(project_id: "X"))
      expect(bad.alert).to match(/Id do projeto/)
      bad = Integrations::GoogleHomePlugin.login(integration, ActionController::Parameters.new(service_account: '{"type":"user"}'))
      expect(bad.alert).to match(/Conta de serviço/)
      target = Exposure::Google.new(site)
      expect(target.set!(hidden.reload.tap { |p| p.update!(risk: "critical") }, true)).to match(/crítico/)
      expect(target.set!(hidden, true, confirm: "1")).to be_nil
      expect(target.exposed?(hidden.reload)).to be true
    end
  end

  it "trait e relator novos entram por registro (stub_const), sem mudar o núcleo" do
    trait = Class.new(GoogleHome::Traits::Base) do
      describe trait: "TesteNivel", type: "SENSOR"
      def self.applies?(p) = p.capability == "text"
      def self.state(_p, v) = { "texto" => v }
    end
    stub_const("GoogleHome::Traits::TesteNivel", trait)
    stub_const("GoogleHome::Traits::PLUGINS", GoogleHome::Traits::PLUGINS + %w[TesteNivel])
    seen = []
    reporter = Class.new { define_singleton_method(:wants?) { |p| p.capability == "text" }; define_singleton_method(:report!) { |_s, pts| seen.concat(pts.map(&:name)) } }
    stub_const("TesteRelator", reporter)
    stub_const("StateReport::REPORTERS", StateReport::REPORTERS + %w[TesteRelator])
    within(tenant) do
      note = create(:point, device: device, name: "Teste Recado", capability: "text", value: "oi", expose: { "google" => true })
      expect(GoogleHome.device(note)).to include("traits" => [ "action.devices.traits.TesteNivel" ], "type" => "action.devices.types.SENSOR")
      expect(GoogleHome.state(note)).to eq("online" => true, "texto" => "oi")
      StateReportJob.perform_now(note.id, StateReport.reporters.select { |r| r.wants?(note) }.map(&:name))
    end
    expect(seen).to eq([ "Teste Recado" ])
  end
end
