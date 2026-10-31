require "rails_helper"

RSpec.describe "Integrações e dispositivos do local (F8c)" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  before { sign_in }

  it "tela: catálogo pesquisável e formulário de cada tipo" do
    get "/locais/#{site.id}/integracoes"
    expect(response.body).to include("Nenhuma integração", "Tuya / Smart Life", "Zigbee2MQTT", "Importar do Home Assistant")
    get "/locais/#{site.id}/integracoes", params: { q: "câmera" }
    expect(response.body).to include("Câmeras / DVR")
    expect(response.body).not_to include("Tuya / Smart Life")
    get "/locais/#{site.id}/integracoes", params: { q: "nada-disso" }
    expect(response.body).to include("Nenhuma integração com")

    { "tuya" => "Código de usuário", "xiaomi" => "Servidor da conta", "alexa" => "Cookies da sessão", "hikvision" => "Porta HTTP",
      "mqtt" => "broker", "zigbee2mqtt" => "coordenador", "ha_import" => "core.config_entries" }.each do |tipo, text|
      get "/locais/#{site.id}/integracoes/nova", params: { tipo: tipo }
      expect(response.body).to include(text)
    end
    get "/locais/#{site.id}/integracoes/nova", params: { tipo: "zzz" }
    expect(response).to redirect_to("/locais/#{site.id}/integracoes#adicionar")
  end

  it "Tuya: código → QR → app confirma → varredura pela fila → encontrados → adicionar todos" do
    post "/locais/#{site.id}/integracoes", params: { tipo: "tuya", integration: { user_code: "" } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Informe o código")

    post "/locais/#{site.id}/integracoes", params: { tipo: "tuya", integration: { user_code: " abc " } }
    integration = within(tenant) { Integration.sole }
    expect(response).to redirect_to("/integracoes/#{integration.id}/conectar")
    expect(integration).to have_attributes(status: "pending", poll_s: 6 * 3600)

    stub_request(:post, /qrcode\/tokens\?clientid=.*usercode=abc/).to_return(body: { success: true, result: { qrcode: "QR1" } }.to_json)
    get "/integracoes/#{integration.id}/conectar"
    expect(response.body).to include("Escaneie com o app Smart Life", "<svg", "data-controller=\"poll\"")

    stub_request(:get, /qrcode\/tokens\/QR1/).to_return({ body: { success: false }.to_json },
                                                        { body: { success: true, t: 1, result: { endpoint: "https://apigw.tuyaus.com", terminal_id: "T", username: "eu@x",
                                                                                                 access_token: "A", refresh_token: "R", expire_time: 7200 } }.to_json })
    get "/integracoes/#{integration.id}/estado"
    expect(response.parsed_body).to eq({})
    expect { get "/integracoes/#{integration.id}/estado" }.to have_enqueued_job(SyncIntegrationJob)
    expect(response.parsed_body).to eq("url" => "/integracoes/#{integration.id}/encontrados")
    integration.reload
    expect(integration.settings["account"]).to eq("eu@x")
    expect(integration.secrets).to include("endpoint" => "https://apigw.tuyaus.com", "qr" => nil)
    get "/integracoes/#{integration.id}/estado"
    expect(response.parsed_body).to eq({})
    get "/integracoes/#{integration.id}/encontrados"
    expect(response.body).to include("Varrendo a conta")

    entries = [ { "id" => "d1", "kind" => "tuya_local", "name" => "Lâmpada", "room" => "Quarto", "category" => "dj", "secret" => "k",
                  "points" => [ { "name" => "Luz", "capability" => "onoff", "address" => { "dps" => "20" } } ] },
                { "id" => "d2", "kind" => "tuya_cloud", "name" => "Sensor Zigbee", "sub" => true, "address" => { "via" => "d1" }, "points" => [] } ]
    allow(Integrations::TuyaPlugin).to receive(:inventory).and_return(entries)
    SyncIntegrationJob.perform_now(integration.id)
    get "/integracoes/#{integration.id}/estado", params: { sync: 1 }
    expect(response.parsed_body["url"]).to be_present
    get "/integracoes/#{integration.id}/encontrados"
    expect(response.body).to include("Lâmpada", "Nova: Quarto", "Adicionar todos", "Sensor Zigbee", "pelo hub Lâmpada")

    get "/locais/#{site.id}/integracoes"
    expect(response.body).to include("2 novo(s) para adicionar", "Conectada", "eu@x", "Ver dispositivos")

    post "/integracoes/#{integration.id}/adicionar", params: { all: 1, area: { "d1" => "new:Quarto" } }
    expect(response).to redirect_to("/locais/#{site.id}/dispositivos?integracao=#{integration.id}")
    expect(within(tenant) { site.devices.find_by!(name: "Sensor Zigbee").address }).to eq("via" => "d1")
    device = within(tenant) { site.devices.find_by!(name: "Lâmpada") }
    expect(device).to have_attributes(name: "Lâmpada", integration_id: integration.id, credential: "k")
    expect(within(tenant) { device.area.name }).to eq("Quarto")
    follow_redirect!
    expect(response.body).to include("Lâmpada", "Quarto", "Smart Life", "Novo")

    get "/integracoes/#{integration.id}/encontrados"
    expect(response.body).to include("Nada novo para adicionar", "2 já no local")
    expect { post "/integracoes/#{integration.id}/sincronizar" }.to have_enqueued_job(SyncIntegrationJob)

    stub_request(:post, /usercode=novo/).to_return(body: { success: false, msg: "user code invalid" }.to_json)
    post "/integracoes/#{integration.id}/conectar", params: { integration: { user_code: "novo" } }
    follow_redirect!
    expect(response.body).to include("user code invalid", "Não deu para gerar o QR")
  end

  it "varredura falhou: rede oferece Tentar de novo; credencial oferece Reconfigurar" do
    integration = within(tenant) do
      site.integrations.create!(driver: "xiaomi", name: "Xiaomi", credentials: { region: "us", user_id: "1", ssecurity: Base64.strict_encode64("s" * 16), service_token: "ST" }.to_json)
    end
    stub_request(:post, /api\.io\.mi\.com/).to_timeout
    within(tenant) { expect { Integrations.sync!(integration) }.to raise_error(Integrations::Error) }
    get "/integracoes/#{integration.id}/encontrados"
    expect(response.body).to include("OpenTimeout em us.api.io.mi.com", "Tentar de novo", "Voltar às integrações")
    expect(response.body).not_to include("Reconfigurar")
    expect { post "/integracoes/#{integration.id}/sincronizar" }.to have_enqueued_job(SyncIntegrationJob) # sem novo login

    stub_request(:post, /api\.io\.mi\.com/).to_return(status: 401)
    within(tenant) { expect { Integrations.sync!(integration.reload) }.to raise_error(Integrations::AuthError) }
    get "/integracoes/#{integration.id}/encontrados"
    expect(response.body).to include("expirou", "Reconfigurar", "Voltar às integrações")
    expect(response.body).not_to include("Tentar de novo")
    within(tenant) { integration.reload.ok! }
    expect(within(tenant) { integration.reload.auth_error? }).to be false
  end

  it "Xiaomi: senha com captcha e 2FA; QR do Mi Home" do
    post "/locais/#{site.id}/integracoes", params: { tipo: "xiaomi", integration: { username: "", password: "" } }
    expect(response).to have_http_status(:unprocessable_content)

    stub_request(:get, /serviceLogin\?/).to_return(body: "&&&START&&&#{{ _sign: 'S' }.to_json}")
    stub_request(:post, /serviceLoginAuth2/).to_return({ body: "&&&START&&&#{{ captchaUrl: '/cap' }.to_json}" },
                                                      { body: "&&&START&&&#{{ notificationUrl: 'https://x' }.to_json}" },
                                                      { body: "&&&START&&&#{{ code: 1 }.to_json}" },
                                                      { body: "&&&START&&&#{{ ssecurity: Base64.strict_encode64('s' * 16), userId: 1, location: 'https://sts.api.io.mi.com/sts' }.to_json}" })
    stub_request(:get, "https://account.xiaomi.com/cap").to_return(body: "IMG")
    stub_request(:get, "https://sts.api.io.mi.com/sts").to_return(headers: { "Set-Cookie" => "serviceToken=ST; path=/" })

    post "/locais/#{site.id}/integracoes", params: { tipo: "xiaomi", integration: { username: "eu@x", password: "p", region: "us" } }
    integration = within(tenant) { Integration.sole }
    expect(response).to redirect_to("/integracoes/#{integration.id}/conectar")
    follow_redirect!
    expect(response.body).to include("digite o que aparece na imagem", "data:image/jpeg;base64,#{Base64.strict_encode64('IMG')}")

    post "/integracoes/#{integration.id}/conectar", params: { integration: { captcha: "abcd", password: "p" } }
    expect(response).to redirect_to("/integracoes/#{integration.id}/conectar?etapa=2fa")
    follow_redirect!
    expect(response.body).to include("verificação em duas etapas", "Entrar com o QR code")

    post "/integracoes/#{integration.id}/conectar", params: { integration: { password: "errada" } }
    follow_redirect!
    expect(response.body).to include("não conferem")
    expect(within(tenant) { integration.reload.status }).to eq("error")

    expect { post "/integracoes/#{integration.id}/conectar", params: { integration: { password: "p" } } }.to have_enqueued_job(SyncIntegrationJob)
    expect(response).to redirect_to("/integracoes/#{integration.id}/encontrados")

    stub_request(:get, /longPolling\/loginUrl/).to_return(body: "&&&START&&&#{{ qr: 'https://account.xiaomi.com/qr.png', lp: 'https://lp.x/p' }.to_json}")
    stub_request(:get, "https://account.xiaomi.com/qr.png").to_return(body: "PNG")
    post "/locais/#{site.id}/integracoes", params: { tipo: "xiaomi", integration: { modo: "qr" } }
    qr = within(tenant) { Integration.order(:created_at).last }
    expect(response).to redirect_to("/integracoes/#{qr.id}/conectar?modo=qr")
    follow_redirect!
    expect(response.body).to include("Escaneie com o app Mi Home", "data:image/png;base64,#{Base64.strict_encode64('PNG')}")
    get "/integracoes/#{qr.id}/estado"
    expect(response.parsed_body).to eq({})
    expect(WebMock).not_to have_requested(:get, "https://lp.x/p") # a espera é do worker
    stub_request(:get, "https://lp.x/p").to_raise(SocketError)
    XiaomiQrLoginJob.wait(qr.id)
    get "/integracoes/#{qr.id}/estado"
    expect(response.parsed_body["error"]).to include("Sem conexão")
  end

  it "câmeras/DVR, MQTT, Alexa e importar do HA" do
    post "/locais/#{site.id}/integracoes", params: { tipo: "hikvision", integration: { host: "10.0.0.9" } }
    expect(response).to have_http_status(:unprocessable_content)

    allow(Isapi).to receive(:inventory).and_return([ { "id" => "10.0.0.9", "kind" => "go2rtc", "match" => "host", "name" => "DVR Casa",
                                                       "address" => { "host" => "10.0.0.9", "port" => 554, "username" => "admin" },
                                                       "points" => [ { "name" => "Garagem", "capability" => "stream", "history" => "none", "address" => { "path" => "/Streaming/Channels/102" } } ] } ])
    post "/locais/#{site.id}/integracoes", params: { tipo: "hikvision", integration: { host: "10.0.0.9", username: "admin", password: "senha" } }
    dvr = within(tenant) { Integration.find_by!(driver: "hikvision") }
    expect(response).to redirect_to("/integracoes/#{dvr.id}/encontrados")
    post "/integracoes/#{dvr.id}/adicionar", params: { pick: [ "10.0.0.9" ] }
    cam = within(tenant) { site.devices.find_by!(driver: "go2rtc") }
    expect(cam).to have_attributes(credential: "senha", address: include("host" => "10.0.0.9"))
    expect(within(tenant) { cam.points.sole }).to have_attributes(capability: "stream", address: { "path" => "/Streaming/Channels/102" })

    allow(Isapi).to receive(:inventory).and_raise(Isapi::Error, "Usuário ou senha do DVR não conferem.")
    post "/integracoes/#{dvr.id}/conectar", params: { integration: { password: "x" } }
    follow_redirect!
    expect(response.body).to include("Não deu para ler o DVR")

    post "/locais/#{site.id}/integracoes", params: { tipo: "zigbee2mqtt" }
    expect(flash[:notice]).to include("Zigbee2MQTT adicionada")
    post "/locais/#{site.id}/integracoes", params: { tipo: "mqtt" }
    expect(within(tenant) { site.integrations.where(driver: "mqtt").count }).to eq(1)

    post "/locais/#{site.id}/integracoes", params: { tipo: "alexa", integration: { cookies: "não é json" } }
    expect(response.body).to include("Não deu para conectar")
    stub_request(:get, %r{alexa.amazon.com.br/api/devices-v2}).to_return(body: { devices: [] }.to_json)
    post "/locais/#{site.id}/integracoes", params: { tipo: "alexa", integration: { cookies: { "csrf" => "1" }.to_json } }
    expect(flash[:notice]).to include("Alexa conectada")
    alexa = within(tenant) { Integration.find_by!(driver: "alexa") }
    post "/integracoes/#{alexa.id}/conectar", params: { integration: { cookies: "{" } }
    expect(response).to redirect_to("/integracoes/#{alexa.id}/conectar")

    post "/locais/#{site.id}/integracoes", params: { tipo: "ha_import", integration: {} }
    expect(response.body).to include("Escolha o arquivo")
    file = Rack::Test::UploadedFile.new(StringIO.new({ data: { entries: [
      { domain: "localtuya", data: { devices: { "x" => { device_id: "lt1", friendly_name: "Tomada HA", host: "10.0.0.7", local_key: "kk",
                                                          protocol_version: "3.4", entities: [ { platform: "switch", id: 1, friendly_name: "Tomada" } ] } } } },
      { domain: "outra", data: { token: "segredo" } }
    ] } }.to_json), "application/json", original_filename: "core.config_entries")
    post "/locais/#{site.id}/integracoes", params: { tipo: "ha_import", integration: { arquivo: file } }
    expect(flash[:notice]).to include("1 dispositivo(s), 1 ponto(s)")
    expect(within(tenant) { site.devices.find_by!(external_id: "lt1").address }).to include("host" => "10.0.0.7", "version" => "3.4")
    bad = Rack::Test::UploadedFile.new(StringIO.new("{x"), "application/json", original_filename: "x.json")
    post "/locais/#{site.id}/integracoes", params: { tipo: "ha_import", integration: { arquivo: bad } }
    expect(response.body).to include("Arquivo inválido")

    delete "/integracoes/#{dvr.id}"
    expect(flash[:notice]).to include("continuam no local")
    expect(within(tenant) { cam.reload.integration_id }).to be_nil
  end

  describe "lista de dispositivos e página do dispositivo" do
    let!(:sala) { within(tenant) { create(:area, site: site, name: "Sala") } }
    let!(:conta) { within(tenant) { site.integrations.create!(driver: "tuya", name: "Smart Life", status: "ok") } }
    let!(:lamp) { within(tenant) { create(:device, site: site, area: sala, name: "Lâmpada", driver: "tuya_local", model: "LED", integration: conta, address: { "host" => "10.0.0.2", "version" => "3.3" }, last_seen_at: Time.current) } }
    let!(:velha) { within(tenant) { create(:device, site: site, name: "Velha", created_at: 1.month.ago, status: "offline") } }
    let!(:sumiu) { within(tenant) { create(:device, site: site, name: "Sumiu", removed_at: Time.current, integration: conta) } }
    let!(:nova) { within(tenant) { create(:device, site: site, name: "Adotada", integration: conta, discovered_at: Time.current) } }

    it "filtra por integração, área, situação e texto; ações em massa" do
      get "/locais/#{site.id}/dispositivos"
      expect(response.body).to include("Lâmpada", "Velha", "Sumiu", "Removido da conta", "Sem sinal", "Com os marcados")
      get "/locais/#{site.id}/dispositivos", params: { integracao: conta.id, situacao: "new" }
      expect(response.body).to include("Adotada", "Novo")
      expect(response.body).not_to include("Sumiu", "Lâmpada")
      get "/locais/#{site.id}/dispositivos", params: { situacao: "online" }
      expect(response.body).to include("Lâmpada")
      expect(response.body).not_to include("Adotada")
      get "/locais/#{site.id}/dispositivos", params: { area: "none", q: "vel" }
      expect(response.body).to include("Velha")
      expect(response.body).not_to include("Lâmpada")
      %w[online offline error removed].each { |s| get("/locais/#{site.id}/dispositivos", params: { situacao: s }) && expect(response).to(have_http_status(:ok)) }
      get "/locais/#{site.id}/dispositivos", params: { q: "nada" }
      expect(response.body).to include("Nenhum dispositivo com esses filtros")

      post "/locais/#{site.id}/dispositivos/lote", params: { ids: [ velha.id, lamp.id ], acao: "area", area_id: sala.id, q: "x" }
      expect(response).to redirect_to("/locais/#{site.id}/dispositivos?q=x")
      expect(within(tenant) { velha.reload.area }).to eq(sala)
      post "/locais/#{site.id}/dispositivos/lote", params: { ids: [ velha.id ], acao: "poll_off" }
      expect(within(tenant) { velha.reload.poll_s }).to eq(0)
      post "/locais/#{site.id}/dispositivos/lote", params: { ids: [ velha.id ], acao: "poll_on" }
      expect(within(tenant) { velha.reload.poll_s }).to eq(1800)
      post "/locais/#{site.id}/dispositivos/lote", params: { ids: [ velha.id ], acao: "" }
      expect(flash[:alert]).to include("ação")
      post "/locais/#{site.id}/dispositivos/lote", params: { acao: "remove" }
      expect(flash[:alert]).to include("ao menos um")
      post "/locais/#{site.id}/dispositivos/lote", params: { ids: [ sumiu.id ], acao: "remove" }
      expect(within(tenant) { Device.exists?(sumiu.id) }).to be false
    end

    it "página: diagnóstico, onde é usado, reconectar e IP/versão no formulário" do
      point = within(tenant) { create(:point, device: lamp, name: "Luz", key: "sala.luz") }
      within(tenant) do
        site.scenes.create!(name: "Noite", items: [ { point_id: point.id, command: "on" } ])
        site.dashboards.new(name: "Painel da sala", definition: { "views" => [ { "cards" => [ { "point" => "sala.luz" } ] } ] }).save!(validate: false)
        lamp.update_columns(last_error: "29/10 10:00 sem conexão")
        point.report!(true)
        point.report!(true, quality: "unavailable")
      end
      get "/dispositivos/#{lamp.id}"
      expect(response.body).to include("Diagnóstico", "10.0.0.2", "3.3", "Smart Life", "Último erro", "sem conexão", "Falhas recentes",
                                       "Onde é usado", "Noite", "Painel da sala", "Reconectar")
      expect { post "/dispositivos/#{lamp.id}/reconectar" }.to have_enqueued_job(PollDeviceJob).with(lamp.id, reconnect: true)
      post "/dispositivos/#{velha.id}/reconectar"
      expect(flash[:alert]).to include("não tem leitura")
      get "/dispositivos/#{velha.id}"
      expect(response.body).to include("Nenhum painel")
      get "/dispositivos/#{sumiu.id}"
      expect(response.body).to include("Sumiu da conta")

      get "/dispositivos/#{lamp.id}/editar"
      expect(response.body).to include("IP na rede local", "Versão do protocolo Tuya")
      patch "/dispositivos/#{lamp.id}", params: { device: { host: "10.0.0.3", protocol_version: "3.4" } }
      expect(within(tenant) { lamp.reload.address }).to eq("host" => "10.0.0.3", "version" => "3.4")
      patch "/dispositivos/#{lamp.id}", params: { device: { host: "" } }
      expect(within(tenant) { lamp.reload.address }).to eq("version" => "3.4")
    end
  end
end
