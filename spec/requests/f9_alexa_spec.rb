require "rails_helper"

# Diretivas de exemplo no formato da documentação da Amazon (Smart Home v3).
RSpec.describe "F9: Alexa Smart Home" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:device) { within(tenant) { create(:device, site: site, name: "Escritório", driver: "virtual") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Monitor 2", value: false, writable: true, alexa_exposed: true) } }
  let!(:dimmer) { within(tenant) { create(:point, device: device, name: "Brilho", capability: "dimmer", min: 0, max: 255, value: 128, writable: true, alexa_exposed: true) } }
  let!(:pct) { within(tenant) { create(:point, device: device, name: "Persiana", capability: "setpoint", unit: "%", min: 0, max: 100, value: 10, writable: true, alexa_exposed: true) } }
  let!(:temp) { within(tenant) { create(:point, device: device, name: "Alvo", capability: "setpoint", unit: "°C", min: 16, max: 30, value: 22, writable: true, alexa_exposed: true) } }
  let!(:num) { within(tenant) { create(:point, device: device, name: "Minutos de rega", capability: "setpoint", min: 0, max: 60, step: 5, value: 10, writable: true, alexa_exposed: true) } }
  let!(:gate) do
    within(tenant) do
      create(:point, device: device, name: "Portão", capability: "gate", value: "closed", options: %w[open closed], risk: "critical", writable: true,
                     alexa_exposed: true, alexa_risk_confirmed: true, alexa_name: "portão da garagem")
    end
  end
  let!(:hidden) { within(tenant) { create(:point, device: device, name: "Sirene", value: false, writable: true, risk: "critical") } }
  let!(:sensor) { within(tenant) { create(:point, device: device, name: "Porta", capability: "contact", value: false, alexa_exposed: true) } }
  let!(:scene) { within(tenant) { Scene.create!(site: site, name: "Cinema", items: [ { "point_id" => lamp.id, "command" => "on" } ], alexa_exposed: true) } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  def alexa_token(u = user)
    within(tenant) do
      code = ApiToken.alexa_code!(u, site, "https://layla.amazon.com/api/skill/link/X")
      _t, access, = ApiToken.redeem_alexa_code(code, "https://layla.amazon.com/api/skill/link/X")
      access
    end
  end

  def directive(namespace, name, token:, endpoint: nil, payload: {}, instance: nil)
    header = { namespace: namespace, name: name, payloadVersion: "3", messageId: "1bd5d003-31b9-476f-ad03-71d471922820", correlationToken: "dFMb0z+PgpgdDmluhJ1LddFvSqZ/jCc8ptlAKulUj90jSqg==", instance: instance }.compact
    d = { header: header, payload: payload }
    d[:endpoint] = { scope: { type: "BearerToken", token: token }, endpointId: endpoint, cookie: {} } if endpoint
    d[:payload] = { scope: { type: "BearerToken", token: token } } if namespace == "Alexa.Discovery"
    post "/alexa/smart_home", params: { directive: d }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    json
  end

  def prop(res, name) = res.dig("context", "properties").find { |p| p["name"] == name }&.dig("value")

  describe "exposição" do
    it "ponto crítico só expõe com confirmação; nome falado; desligado por padrão" do
      within(tenant) do
        expect(hidden.alexa_exposed).to be(false)
        expect(hidden.update(alexa_exposed: true)).to be(false)
        expect(hidden.errors.full_messages.join).to include("precisa da confirmação")
        hidden.alexa_risk_confirmed = "1"
        expect(hidden.update(alexa_exposed: true)).to be(true)
        expect(gate.alexa_label).to eq("portão da garagem")
        expect(lamp.alexa_label).to eq("Monitor 2")
      end
    end

    it "tela: lista o que a Alexa entende, salva, pede confirmação no crítico e desvincula" do
      sign_in
      get "/locais/#{site.id}/alexa"
      expect(response.body).to include("Expor para a Alexa", "Monitor 2", "Cinema", "PowerController", "Crítico", "Confirmo expor Portão", "código de voz")
      expect(response.body).not_to include(">Porta<") # sensor de abertura: sem interface
      patch "/locais/#{site.id}/alexa", params: { items: { lamp.id => { exposed: "0", name: "" }, hidden.id => { exposed: "1", name: "sirene" } } }
      expect(flash[:alert]).to include("confirmação")
      within(tenant) { expect([ lamp.reload.alexa_exposed, hidden.reload.alexa_exposed ]).to eq([ false, false ]) }
      patch "/locais/#{site.id}/alexa", params: { items: { hidden.id => { exposed: "1", name: "sirene", confirm: "1" }, "scene-#{scene.id}" => { exposed: "1", name: "modo cinema" } } }
      expect(flash[:notice]).to include("descobrir dispositivos")
      within(tenant) do
        expect(hidden.reload).to have_attributes(alexa_exposed: true, alexa_name: "sirene")
        expect(scene.reload.alexa_name).to eq("modo cinema")
        expect(AuditEvent.where(auditable_id: hidden.id, action: "update").pluck(:details).to_s).to include("alexa_exposed")
      end

      token = alexa_token
      get "/locais/#{site.id}/alexa"
      link = within(tenant) { ApiToken.alexa.where.not(last_used_at: nil).sole }
      expect(response.body).to include("Contas da Alexa vinculadas", user.name)
      delete "/locais/#{site.id}/alexa/vinculos/#{link.id}"
      expect(directive("Alexa.Discovery", "Discover", token: token).dig("event", "payload", "type")).to eq("INVALID_AUTHORIZATION_CREDENTIAL")
    end

    it "membro sem papel de dono no local não muda nada" do
      guest = create(:user, tenant: tenant, role: "member")
      within(tenant) { create(:site_membership, site: site, user: guest, role: "resident") }
      sign_in(guest)
      get "/locais/#{site.id}/alexa"
      expect(response.body).not_to include("Gerar cliente")
      patch "/locais/#{site.id}/alexa", params: { items: { lamp.id => { exposed: "0" } } }
      within(tenant) { expect(lamp.reload.alexa_exposed).to be(true) }
    end
  end

  describe "account linking (OAuth 2.0)" do
    let(:redirect) { "https://layla.amazon.com/api/skill/link/M2AAAAAAAAAAAA" }

    it "gera o cliente, autoriza com escolha do local, troca o código uma vez e renova" do
      sign_in
      post "/locais/#{site.id}/alexa/cliente", params: { generate: "1", redirect_uris: "#{redirect}\nhttp://inseguro" }
      secret = response.body[/Client Secret \(só agora\)<\/dt><dd[^>]*>([^<]+)</, 1]
      expect(secret).to be_present
      tenant.reload
      expect(tenant.alexa_redirect_uris).to eq([ redirect ])
      client_id = tenant.alexa_client_id

      get "/oauth/autorizar", params: { client_id: "outro", redirect_uri: redirect, state: "abc", response_type: "code" }
      expect(response).to have_http_status(:bad_request)
      get "/oauth/autorizar", params: { client_id: client_id, redirect_uri: "https://mal.com/cb", state: "abc" }
      expect(response).to have_http_status(:bad_request)
      get "/oauth/autorizar", params: { client_id: client_id, redirect_uri: redirect, state: "abc", response_type: "code", scope: "casa" }
      expect(response.body).to include("Vincular a Alexa", "Casa", "Permitir")

      post "/oauth/autorizar", params: { client_id: client_id, redirect_uri: redirect, state: "abc", site_id: site.id, deny: "Não permitir" }
      expect(response.location).to eq("#{redirect}?error=access_denied&state=abc")
      post "/oauth/autorizar", params: { client_id: client_id, redirect_uri: redirect, state: "abc", site_id: site.id }
      expect(response.location).to start_with("#{redirect}?code=")
      code = Rack::Utils.parse_query(URI(response.location).query)["code"]

      basic = { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(client_id, secret) }
      post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: redirect }, headers: { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(client_id, "errado") }
      expect([ response.status, json ]).to eq([ 401, { "error" => "invalid_client" } ])
      post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: "https://outra" }, headers: basic
      expect(json).to eq("error" => "invalid_grant")
      post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: redirect }, headers: basic
      expect(json).to include("token_type" => "Bearer", "expires_in" => 1800)
      access, refresh = json.values_at("access_token", "refresh_token")
      post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: redirect }, headers: basic
      expect(json).to eq("error" => "invalid_grant") # uso único

      post "/oauth/token", params: { grant_type: "refresh_token", refresh_token: refresh, client_id: client_id, client_secret: secret }
      expect(json["access_token"]).to be_present.and(satisfy { |a| a != access })
      post "/oauth/token", params: { grant_type: "password" }, headers: basic
      expect(json).to eq("error" => "unsupported_grant_type")

      # O token da Alexa não abre a API do app, e o do app não abre a Alexa.
      get "/api/v1/me", headers: { "Authorization" => "Bearer #{json['access_token'] || access}" }
      expect(response).to have_http_status(:unauthorized)
      _t, app_access, = ApiToken.issue(user)
      expect(directive("Alexa.Discovery", "Discover", token: app_access).dig("event", "payload", "type")).to eq("INVALID_AUTHORIZATION_CREDENTIAL")
      expect(within(tenant) { AuditEvent.where(action: "alexa.link").count }).to eq(1)

      post "/locais/#{site.id}/alexa/cliente", params: { redirect_uris: "#{redirect}\nhttps://pitangui.amazon.com/x" }
      expect(tenant.reload.alexa_redirect_uris.size).to eq(2)
    end

    it "código de outra instalação não vale" do
      other = create(:tenant)
      secret = other.generate_alexa_client!("https://x.com/cb")
      code = within(tenant) { ApiToken.alexa_code!(user, site, "https://x.com/cb") }
      post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: "https://x.com/cb", client_id: other.alexa_client_id, client_secret: secret }
      expect(json).to eq("error" => "invalid_grant")
    end
  end

  describe "diretivas" do
    let!(:token) { alexa_token }

    it "Discovery: só o exposto, com interfaces pelo registro e categoria" do
      res = directive("Alexa.Discovery", "Discover", token: token)
      expect(res.dig("event", "header")).to include("namespace" => "Alexa.Discovery", "name" => "Discover.Response", "payloadVersion" => "3")
      eps = res.dig("event", "payload", "endpoints").index_by { |e| e["friendlyName"] }
      expect(eps.keys).to contain_exactly("Monitor 2", "Brilho", "Persiana", "Alvo", "Minutos de rega", "portão da garagem", "Cinema")
      ifaces = ->(n) { eps[n]["capabilities"].map { |c| c["interface"] } }
      expect(ifaces.("Monitor 2")).to eq(%w[Alexa Alexa.PowerController Alexa.EndpointHealth])
      expect(eps["Monitor 2"]["displayCategories"]).to eq([ "LIGHT" ])
      expect(ifaces.("Brilho")).to include("Alexa.BrightnessController")
      expect(ifaces.("Persiana")).to include("Alexa.PercentageController")
      expect(ifaces.("Alvo")).to include("Alexa.ThermostatController")
      expect(ifaces.("Minutos de rega")).to include("Alexa.RangeController")
      range = eps["Minutos de rega"]["capabilities"].find { |c| c["interface"] == "Alexa.RangeController" }
      expect(range.dig("configuration", "supportedRange")).to eq("minimumValue" => 0.0, "maximumValue" => 60.0, "precision" => 5.0)
      expect(eps["portão da garagem"]["displayCategories"]).to eq([ "SMARTLOCK" ])
      expect(eps["Cinema"]).to include("endpointId" => "scene-#{scene.id}", "displayCategories" => [ "SCENE_TRIGGER" ])
    end

    it "PowerController liga e desliga com o estado na resposta; ReportState" do
      res = directive("Alexa.PowerController", "TurnOn", token: token, endpoint: lamp.id)
      expect(res.dig("event", "header")).to include("namespace" => "Alexa", "name" => "Response", "correlationToken" => "dFMb0z+PgpgdDmluhJ1LddFvSqZ/jCc8ptlAKulUj90jSqg==")
      expect(prop(res, "powerState")).to eq("ON")
      expect(within(tenant) { [ lamp.reload.value, Command.last.source, Command.last.user_id ] }).to eq([ true, "alexa", user.id ])
      res = directive("Alexa", "ReportState", token: token, endpoint: lamp.id)
      expect(res.dig("event", "header", "name")).to eq("StateReport")
      expect(prop(res, "powerState")).to eq("ON")
      expect(prop(res, "connectivity")).to eq("value" => "OK")
      expect(prop(directive("Alexa.PowerController", "TurnOff", token: token, endpoint: lamp.id), "powerState")).to eq("OFF")
    end

    it "Brightness, Percentage, Thermostat, Range e Lock traduzem para o comando do ponto" do
      expect(prop(directive("Alexa.BrightnessController", "SetBrightness", token: token, endpoint: dimmer.id, payload: { brightness: 100 }), "brightness")).to eq(100)
      expect(within(tenant) { dimmer.reload.value }).to eq(255)
      expect(prop(directive("Alexa.BrightnessController", "AdjustBrightness", token: token, endpoint: dimmer.id, payload: { brightnessDelta: -50 }), "brightness")).to eq(50)
      expect(prop(directive("Alexa.PercentageController", "SetPercentage", token: token, endpoint: pct.id, payload: { percentage: 74 }), "percentage")).to eq(74)
      expect(prop(directive("Alexa.PercentageController", "AdjustPercentage", token: token, endpoint: pct.id, payload: { percentageDelta: 6 }), "percentage")).to eq(80)
      res = directive("Alexa.ThermostatController", "SetTargetTemperature", token: token, endpoint: temp.id, payload: { targetSetpoint: { value: 24.0, scale: "CELSIUS" } })
      expect(prop(res, "targetSetpoint")).to eq("value" => 24.0, "scale" => "CELSIUS")
      res = directive("Alexa.ThermostatController", "AdjustTargetTemperature", token: token, endpoint: temp.id, payload: { targetSetpointDelta: { value: -2.0, scale: "CELSIUS" } })
      expect(prop(res, "targetSetpoint")["value"]).to eq(22.0)
      res = directive("Alexa.ThermostatController", "SetTargetTemperature", token: token, endpoint: temp.id, payload: { targetSetpoint: { value: 40, scale: "CELSIUS" } })
      expect(res.dig("event", "payload", "type")).to eq("TEMPERATURE_VALUE_OUT_OF_RANGE")
      expect(prop(directive("Alexa.ThermostatController", "SetTargetTemperature", token: token, endpoint: temp.id, payload: { targetSetpoint: { value: 77, scale: "FAHRENHEIT" } }), "targetSetpoint")["value"]).to eq(25.0)
      res = directive("Alexa.RangeController", "SetRangeValue", token: token, endpoint: num.id, payload: { rangeValue: 20 }, instance: "Ponto.Valor")
      expect(res.dig("context", "properties", 0)).to include("name" => "rangeValue", "value" => 20.0, "instance" => "Ponto.Valor")
      expect(prop(directive("Alexa.RangeController", "AdjustRangeValue", token: token, endpoint: num.id, payload: { rangeValueDelta: 5 }), "rangeValue")).to eq(25.0)
      expect(directive("Alexa.RangeController", "SetRangeValue", token: token, endpoint: num.id, payload: { rangeValue: 99 }).dig("event", "payload", "type")).to eq("VALUE_OUT_OF_RANGE")

      expect(prop(directive("Alexa.LockController", "Lock", token: token, endpoint: gate.id), "lockState")).to eq("LOCKED") # já fechado: nada sai
      expect(within(tenant) { gate.commands.count }).to eq(0)
      expect(prop(directive("Alexa.LockController", "Unlock", token: token, endpoint: gate.id), "lockState")).to eq("UNLOCKED")
      expect(within(tenant) { [ gate.reload.value, gate.commands.last.command ] }).to eq([ "open", "pulse" ])
    end

    it "SceneController aciona a cena; erros no formato da Amazon" do
      res = directive("Alexa.SceneController", "Activate", token: token, endpoint: "scene-#{scene.id}")
      expect(res.dig("event", "header", "name")).to eq("ActivationStarted")
      expect(res.dig("event", "payload", "cause", "type")).to eq("VOICE_INTERACTION")
      expect(within(tenant) { lamp.reload.value }).to be(true)
      expect(directive("Alexa.SceneController", "Deactivate", token: token, endpoint: "scene-#{scene.id}").dig("event", "payload", "type")).to eq("INVALID_DIRECTIVE")

      err = ->(res) { [ res.dig("event", "header", "name"), res.dig("event", "payload", "type") ] }
      expect(err.(directive("Alexa.PowerController", "TurnOn", token: "x", endpoint: lamp.id))).to eq([ "ErrorResponse", "INVALID_AUTHORIZATION_CREDENTIAL" ])
      expect(err.(directive("Alexa.PowerController", "TurnOn", token: token, endpoint: hidden.id))).to eq([ "ErrorResponse", "NO_SUCH_ENDPOINT" ])
      expect(err.(directive("Alexa.PowerController", "TurnOn", token: token, endpoint: "scene-#{SecureRandom.uuid}"))).to eq([ "ErrorResponse", "NO_SUCH_ENDPOINT" ])
      expect(err.(directive("Alexa.ColorController", "SetColor", token: token, endpoint: lamp.id))).to eq([ "ErrorResponse", "INVALID_DIRECTIVE" ])
      expect(err.(directive("Alexa.BrightnessController", "SetBrightness", token: token, endpoint: lamp.id, payload: { brightness: 5 }))).to eq([ "ErrorResponse", "INVALID_DIRECTIVE" ])
      expect(err.(directive("Alexa.BrightnessController", "SetBrightness", token: token, endpoint: dimmer.id, payload: { brightness: 500 }))).to eq([ "ErrorResponse", "VALUE_OUT_OF_RANGE" ])
      within(tenant) { lamp.update!(quality: "unavailable") }
      expect(err.(directive("Alexa.PowerController", "TurnOn", token: token, endpoint: lamp.id))).to eq([ "ErrorResponse", "ENDPOINT_UNREACHABLE" ])
      expect(prop(directive("Alexa", "ReportState", token: token, endpoint: lamp.id), "connectivity")).to eq("value" => "UNREACHABLE")

      post "/alexa/smart_home", params: "{nao json", headers: { "CONTENT_TYPE" => "application/json" }
      expect([ response.status, json.dig("event", "payload", "type") ]).to eq([ 400, "INVALID_DIRECTIVE" ])
      post "/alexa/smart_home", params: {}.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      expect(json.dig("event", "payload", "type")).to eq("INVALID_DIRECTIVE")
      res = directive("Alexa.Authorization", "AcceptGrant", token: token, payload: { grant: { type: "OAuth2.AuthorizationCode", code: "VGhpcyBpcyBhIGNvZGU" }, grantee: { type: "BearerToken", token: token } })
      expect(res.dig("event", "header", "name")).to eq("AcceptGrant.Response")
    end

    it "papel x risco: quem não pode acionar o crítico recebe INSUFFICIENT_PERMISSIONS" do
      guest = create(:user, tenant: tenant, role: "member")
      within(tenant) { create(:site_membership, site: site, user: guest, role: "guest") }
      t = alexa_token(guest)
      expect(directive("Alexa.LockController", "Unlock", token: t, endpoint: gate.id).dig("event", "payload", "type")).to eq("INSUFFICIENT_PERMISSIONS")
      expect(prop(directive("Alexa.PowerController", "TurnOn", token: t, endpoint: lamp.id), "powerState")).to eq("ON")
      within(tenant) { SiteMembership.where(user: guest).delete_all }
      expect(directive("Alexa.Discovery", "Discover", token: t).dig("event", "payload", "type")).to eq("INVALID_AUTHORIZATION_CREDENTIAL")
    end
  end
end
