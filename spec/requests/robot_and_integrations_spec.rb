require "rails_helper"

RSpec.describe "Robô no painel e tela de integrações (F8)" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:rooms) { [ { "id" => 5, "name" => "Sala de estar" }, { "id" => 45, "name" => "Cozinha" } ] }
  let!(:robot) do
    within(tenant) do
      Miio::Import.call(site, "did" => 1, "host" => "127.0.0.1", "token" => FakeMiioDevice::TOKEN, "name" => "Robô aspirador", "rooms" => rooms)
      device = site.devices.find_by!(driver: "xiaomi_miot")
      { "Bateria" => 96, "Modo" => "Aspirar antes do pano", "Escova principal" => 12, "Erro" => true }.each { |n, v| device.points.find_by!(name: n).report!(v) }
      device.points.find_by!(capability: "vacuum").tap { |p| p.report!("docked") }
    end
  end

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })
  def dashboard = within(tenant) { Dashboard.ensure_for(site).first }

  before { sign_in }

  it "o painel automático mostra o widget do robô com cômodos, ajustes, base e peças" do
    get "/"
    body = response.body
    expect(body).to include("dw-vacuum", "Robô aspirador", "Na base", "96 %", "Sala de estar", "Cozinha", "Limpar selecionados",
                            "Limpar a casa", "Voltar à base", "Lavar pano", "Esvaziar", "Escova principal", "dw-vac-low", "O robô avisou um erro")
    expect(body).to include(%(name="value[rooms][]"), %(name="value[mode]"), %(<option selected="selected" value="Aspirar antes do pano">))
    expect(within(tenant) { Dashboards::Schema.errors(Dashboards::Generator.call(site)) }).to be_empty
  end

  it "limpar selecionados pelo widget vira comando clean_rooms validado e volta ao quadro" do
    d = dashboard
    wid = "wv-#{robot.id}"
    post "/pontos/#{robot.id}/comando", params: { command: "clean_rooms", value: { rooms: %w[45], mode: "Só aspirar" }, dashboard_id: d.id, widget_id: wid },
                                        headers: { "Turbo-Frame" => "w_#{wid}" }
    expect(response).to redirect_to("/paineis/#{d.id}/w/#{wid}")
    command = within(tenant) { Command.sole }
    expect(command).to have_attributes(command: "clean_rooms", value: { "rooms" => [ 45 ], "mode" => "Só aspirar" }, status: "pending")

    post "/pontos/#{robot.id}/comando", params: { command: "clean_rooms", value: { rooms: [ "" ] }, dashboard_id: d.id, widget_id: wid },
                                        headers: { "Turbo-Frame" => "w_#{wid}" }
    follow_redirect!
    expect(response.body).to include("Escolha ao menos um cômodo")
  end

  it "robô sem conexão: sem botões e com aviso" do
    within(tenant) { robot.report!("docked", quality: "unavailable") }
    get "/paineis/#{dashboard.id}/w/wv-#{robot.id}"
    expect(response.body).to include("Sem conexão")
    expect(response.body).not_to include("Limpar selecionados")
  end

  it "integrações: card da Alexa com estado e resumo (sem lista de aparelhos); sincronizar lê a lista pela fila" do
    integration = within(tenant) do
      site.integrations.create!(driver: "alexa", name: "Alexa", credentials: { "csrf" => "C" }.to_json, status: "error", last_error: "Sessão expirada")
    end
    get "/locais/#{site.id}/integracoes"
    expect(response.body).to include("Alexa (Amazon)", "Com erro", "Sessão expirada", "Sincronizar agora", "Ver dispositivos", "Adicionar integração")

    stub_request(:get, "https://alexa.amazon.com.br/api/devices-v2/device?cached=true")
      .to_return({ body: { devices: [ { accountName: "Echo Sala", deviceFamily: "ECHO", serialNumber: "S", online: true } ] }.to_json }, { status: 401 })
    expect { post "/integracoes/#{integration.id}/sincronizar" }.to have_enqueued_job(SyncIntegrationJob).with(integration.id)
    expect(within(tenant) { integration.reload.status }).to eq("syncing")
    SyncIntegrationJob.perform_now(integration.id)
    expect(within(tenant) { integration.reload.status }).to eq("ok")
    SyncIntegrationJob.perform_now(integration.id)
    expect(within(tenant) { integration.reload.last_error }).to include("expirada")

    get "/locais/#{site.id}/automacao"
    get "/locais/#{site.id}/avisos/novo"
    expect(response.body).to include("Falar na Echo Sala")
  end

  it "visitante vê as integrações mas não atualiza" do
    integration = within(tenant) { site.integrations.create!(driver: "alexa", name: "Alexa") }
    guest = create(:user, tenant: tenant, role: "member")
    within(tenant) { create(:site_membership, site: site, user: guest, role: "guest") }
    sign_in(guest)
    get "/locais/#{site.id}/integracoes"
    expect(response.body).to include("Aguardando login")
    expect(response.body).not_to include("Sincronizar agora")
    post "/integracoes/#{integration.id}/sincronizar"
    expect(response).to have_http_status(:not_found).or have_http_status(:forbidden).or redirect_to("/")
  end
end
