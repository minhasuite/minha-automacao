require "rails_helper"

# F8g: Configurações → Aplicativos (só o dono), tudo pelo supervisor.
RSpec.describe "Aplicativos (F8g)" do
  let(:owner) { create(:user, email: "dono@ex.com") }
  let(:tenant) { owner.tenant }
  let(:base) { "http://supervisor:8099" }
  let(:kuma) do
    { "key" => "uptime_kuma", "installed" => true, "state" => "running", "version" => "1.0.0", "memory_mb" => 80.4,
      "boot" => true, "watchdog" => true, "options" => {} }
  end
  let(:mosq) { { "key" => "mosquitto", "system" => true, "installed" => true, "state" => "running", "version" => "2.0.20" } }

  def sign_in(u = owner) = post("/entrar", params: { email: u.email, password: "12345678" })
  def stub_sup(method, path, body = {}, status: 200) = stub_request(method, "#{base}#{path}").to_return(status: status, body: body.to_json)

  def with_env(vars)
    old = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  around { |ex| with_env("SUPERVISOR_URL" => base, "SUPERVISOR_TOKEN" => "x" * 40) { ex.run } }

  before { sign_in }

  it "só o dono entra" do
    member = create(:user, tenant: tenant, role: "member", email: "m@ex.com")
    sign_in(member)
    get "/configuracoes/aplicativos"
    expect(response).to redirect_to("/")
  end

  it "lista os instalados com estado, memória, atualização e abrir interface" do
    stub_sup(:get, "/apps", { data: [ kuma, mosq, { "key" => "node_red", "installed" => false } ] })
    get "/configuracoes/aplicativos"
    expect(response.body).to include("Uptime Kuma", "Mosquitto", "Rodando", "80 MB", "Atualização disponível: 1.23.16", "Abrir interface", "Aplicativos")
    expect(response.body).not_to include("Node-RED")
  end

  it "sem supervisor mostra só o catálogo e o aviso" do
    with_env("SUPERVISOR_URL" => nil) do
      get "/configuracoes/aplicativos"
      expect(response.body).to include("Disponível no servidor local", "Nenhum aplicativo instalado")
      get "/configuracoes/aplicativos/loja"
      expect(response.body).to include("Frigate", "servidor local")
      get "/configuracoes/aplicativos/uptime_kuma"
      expect(response.body).to include("Disponível no servidor local")
      expect(response.body).not_to include("Instalar</")
    end
  end

  it "supervisor fora do ar vira aviso, não erro" do
    stub_request(:get, "#{base}/apps").to_raise(Errno::ECONNREFUSED)
    get "/configuracoes/aplicativos"
    expect(response.body).to include("fora do ar")
  end

  it "loja procura por texto e categoria e marca o instalado" do
    stub_sup(:get, "/apps", { data: [ kuma ] })
    get "/configuracoes/aplicativos/loja", params: { q: "kuma" }
    expect(response.body).to include("Uptime Kuma", "Instalado")
    expect(response.body).not_to include("Node-RED")
    get "/configuracoes/aplicativos/loja", params: { categoria: "Câmeras" }
    expect(response.body).to include("Frigate", "go2rtc")
    get "/configuracoes/aplicativos/loja", params: { q: "zzz" }
    expect(response.body).to include("Nenhum aplicativo")
  end

  it "página do app: informações, configuração e log" do
    stub_sup(:get, "/apps/uptime_kuma", { data: kuma })
    get "/configuracoes/aplicativos/uptime_kuma"
    expect(response.body).to include("Informações", "Parar", "Reiniciar", "Iniciar com o servidor", "Desinstalar", "Atualizar")
    get "/configuracoes/aplicativos/uptime_kuma", params: { aba: "config" }
    expect(response.body).to include("não tem opções")
    get "/configuracoes/aplicativos/uptime_kuma", params: { aba: "log" }
    expect(response.body).to include("app-log")

    stub_request(:get, "#{base}/apps/uptime_kuma/logs?lines=200").to_return(body: { data: { lines: "pronto <b>" } }.to_json)
    get "/configuracoes/aplicativos/uptime_kuma/log"
    expect(response.body).to include("pronto &lt;b&gt;")
    stub_request(:get, "#{base}/apps/uptime_kuma/logs?lines=200").to_return(status: 422, body: { error: "App não instalado." }.to_json)
    get "/configuracoes/aplicativos/uptime_kuma/log"
    expect(response.body).to include("App não instalado.")

    get "/configuracoes/aplicativos/nada"
    expect(response).to have_http_status(:not_found)
  end

  it "formulário de opções do schema (zigbee2mqtt) e app ocupado recarrega sozinho" do
    stub_sup(:get, "/apps/zigbee2mqtt", { data: { "key" => "zigbee2mqtt", "installed" => false } })
    get "/configuracoes/aplicativos/zigbee2mqtt"
    expect(response.body).to include("Coordenador USB", "options[serial_port]", "ember", "Instalar")

    stub_sup(:get, "/apps/code_server", { data: kuma.merge("key" => "code_server", "options" => { "password" => nil }, "busy" => "Atualizando") })
    get "/configuracoes/aplicativos/code_server", params: { aba: "config" }
    expect(response.body).to include("Em branco mantém a atual", 'data-controller="ss-reload"')

    stub_sup(:get, "/apps/mosquitto", { data: mosq.merge("error" => "falhou") })
    get "/configuracoes/aplicativos/mosquitto"
    expect(response.body).to include("do sistema", "Reiniciar", "falhou")
    expect(response.body).not_to include("Desinstalar")
    get "/configuracoes/aplicativos/mosquitto", params: { aba: "config" }
    expect(response.body).to include("Configurado pelo servidor")
  end

  it "instala, age, configura, atualiza e desinstala, com auditoria" do
    install = stub_sup(:post, "/apps/zigbee2mqtt/install", { data: {} }, status: 202)
    post "/configuracoes/aplicativos/zigbee2mqtt/instalar", params: { options: { serial_port: "/dev/ttyUSB0", evil: "x" }, boot: "1", watchdog: "0" }
    expect(response).to redirect_to("/configuracoes/aplicativos/zigbee2mqtt")
    expect(install.with(body: { options: { serial_port: "/dev/ttyUSB0" }, boot: true, watchdog: false })).to have_been_requested

    stub_sup(:post, "/apps/uptime_kuma/stop", { data: kuma })
    post "/configuracoes/aplicativos/uptime_kuma/acao", params: { do: "stop" }
    expect(flash[:notice]).to eq("Uptime Kuma parado.")
    post "/configuracoes/aplicativos/uptime_kuma/acao", params: { do: "rm" }
    expect(response).to redirect_to("/configuracoes/aplicativos/uptime_kuma")

    conf = stub_sup(:put, "/apps/uptime_kuma/config", { data: kuma })
    patch "/configuracoes/aplicativos/uptime_kuma", params: { boot: "0", watchdog: "1" }
    expect(conf.with(body: { boot: false, watchdog: true })).to have_been_requested
    stub_sup(:put, "/apps/node_red/config", { data: {} }, status: 202)
    patch "/configuracoes/aplicativos/node_red", params: { options: { tz: "UTC" } }
    expect(response).to redirect_to("/configuracoes/aplicativos/node_red?aba=config")

    stub_sup(:post, "/apps/uptime_kuma/update", { data: {} }, status: 202)
    post "/configuracoes/aplicativos/uptime_kuma/atualizar"
    expect(flash[:notice]).to include("1.23.16")

    del = stub_request(:delete, "#{base}/apps/uptime_kuma?keep_data=1").to_return(body: { data: {} }.to_json)
    delete "/configuracoes/aplicativos/uptime_kuma", params: { keep_data: "1" }
    expect(del).to have_been_requested
    expect(flash[:notice]).to include("dados guardados")

    actions = AuditEvent.where(auditable_type: "App").pluck(:action)
    expect(actions).to contain_exactly("app.install", "app.stop", "app.configure", "app.configure", "app.upgrade", "app.uninstall")
    expect(AuditEvent.find_by(action: "app.uninstall").details).to include("key" => "uptime_kuma", "keep_data" => true)
  end

  it "erro do supervisor volta com o aviso" do
    stub_sup(:post, "/apps/zigbee2mqtt/install", { error: "Opções inválidas.", errors: { serial_port: "use /dev/serial/by-id/…" } }, status: 422)
    post "/configuracoes/aplicativos/zigbee2mqtt/instalar", params: { options: { serial_port: "x" } }
    expect(response).to redirect_to("/configuracoes/aplicativos/zigbee2mqtt")
    expect(flash[:alert]).to include("Opções inválidas.", "serial_port")
    stub_request(:post, "#{base}/apps/zigbee2mqtt/install").to_return(status: 500, body: "")
    post "/configuracoes/aplicativos/zigbee2mqtt/instalar"
    expect(flash[:alert]).to eq("Supervisor respondeu 500.")
  end

  it "abrir interface desvia para a porta do app na rede de casa (e audita)" do
    get "/configuracoes/aplicativos/uptime_kuma/abrir", headers: { "Host" => "192.168.68.199" }
    expect(response).to redirect_to("http://192.168.68.199:3001")
    with_env("APP_HOST" => "10.0.0.5") do
      get "/configuracoes/aplicativos/uptime_kuma/abrir"
      expect(response.location).to eq("http://10.0.0.5:3001")
    end
    get "/configuracoes/aplicativos/mosquitto/abrir"
    expect(response).to redirect_to("/configuracoes/aplicativos/mosquitto")
    expect(AuditEvent.where(action: "app.open").count).to eq(2)
  end
end
