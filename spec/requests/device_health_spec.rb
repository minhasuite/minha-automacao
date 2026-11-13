require "rails_helper"

# Tela "Saúde dos aparelhos" (web e app pelo AppScreen): agrupar, filtrar,
# reparar, silenciar, ajustes do local e papel por local.
RSpec.describe "Saúde dos aparelhos" do
  let(:user) { create(:user, role: "owner") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Teste Casa") } }
  let!(:sala) { within(tenant) { create(:area, site: site, name: "Teste Sala") } }
  let!(:tomada) do
    within(tenant) do
      d = create(:device, site: site, area: sala, name: "Teste Tomada", driver: "tuya_local", status: "offline", last_seen_at: 3.hours.ago,
                          address: { "host" => "192.168.0.50" })
      create(:point, device: d, site: site, name: "Teste Tomada estado", capability: "onoff")
      d
    end
  end
  let!(:solto) do
    within(tenant) do
      d = create(:device, site: site, name: "Teste Solto", status: "online", last_seen_at: Time.current)
      create(:point, device: d, site: site, name: "Teste Solto estado", capability: "onoff")
      d
    end
  end

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  before { sign_in }

  it "lista agrupado por problema e por área, com motivo e reparos" do
    get "/saude-aparelhos"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Saúde dos aparelhos", "Sem sinal", "Teste Tomada", "DHCP", "Sem área", "Teste Solto", "Ajustes deste local")
    expect(response.body).to include('data-fix="reconnect"', 'data-fix="set_area"', 'data-group="offline"', 'data-group="no_area"')
    get "/saude-aparelhos", params: { site_id: site.id, agrupar: "area" }
    expect(response.body).to include("data-group=\"#{sala.id}\"", 'data-group="none"')
    get "/saude-aparelhos", params: { site_id: site.id, problema: "offline" }
    expect(response.body).to include("Teste Tomada")
    expect(response.body).not_to include('data-finding="no_area')
    get "/saude-aparelhos", params: { site_id: site.id, severidade: "error" }
    expect(response.body).to include("Nenhum achado com esses filtros")
  end

  it "repara (definir área), silencia e volta a mostrar, guardando os filtros" do
    ref = "no_area:#{solto.id}"
    post "/saude-aparelhos/reparar", params: { site_id: site.id, ref: ref, fix: "set_area", area_id: sala.id, problema: "no_area" }
    expect(response).to redirect_to("/saude-aparelhos?problema=no_area&site_id=#{site.id}")
    expect(flash[:notice]).to eq("Teste Solto agora está em Teste Sala.")
    expect(within(tenant) { solto.reload.area }).to eq(sala)

    post "/saude-aparelhos/reparar", params: { site_id: site.id, ref: ref, fix: "set_area", area_id: sala.id }
    expect(flash[:alert]).to eq("Esse achado não se aplica mais.")
    post "/saude-aparelhos/reparar", params: { site_id: site.id, ref: "offline:#{tomada.id}", fix: "set_area" }
    expect(flash[:alert]).to eq("Esse reparo não serve para esse achado.")
    post "/saude-aparelhos/reparar", params: { site_id: site.id, ref: "offline:#{tomada.id}", fix: "reconnect" }
    expect(flash[:notice]).to include("reconexão pedida")

    post "/saude-aparelhos/silenciar", params: { site_id: site.id, ref: "offline:#{tomada.id}", days: 7 }
    expect(flash[:notice]).to include("silenciado")
    get "/saude-aparelhos", params: { site_id: site.id }
    expect(response.body).to include("Nenhum problema nos aparelhos")
    get "/saude-aparelhos", params: { site_id: site.id, silenciados: "1" }
    expect(response.body).to include("Teste Tomada", "silenciado até", "Voltar a mostrar")
    post "/saude-aparelhos/silenciar", params: { site_id: site.id, ref: "offline:#{tomada.id}", days: 2 }
    expect(flash[:alert]).to eq("Prazo inválido.")
    post "/saude-aparelhos/silenciar", params: { site_id: site.id, ref: "offline:#{tomada.id}", on: "0" }
    expect(flash[:notice]).to eq("Achado voltou a aparecer.")
  end

  it "apaga cadastro removido da conta com confirmação" do
    gone = within(tenant) { create(:device, site: site, area: sala, name: "Teste Sumiu", status: "online", removed_at: 1.day.ago) }
    get "/saude-aparelhos", params: { site_id: site.id, problema: "removed" }
    expect(response.body).to include("data-turbo-confirm=\"Apagar o cadastro de Teste Sumiu?")
    post "/saude-aparelhos/reparar", params: { site_id: site.id, ref: "removed:#{gone.id}", fix: "delete_device" }
    expect(flash[:notice]).to eq("Teste Sumiu: cadastro apagado.")
    expect(within(tenant) { Device.exists?(gone.id) }).to be(false)
    expect(AuditEvent.where(action: "device.orphan_delete", user_id: user.id)).to exist
  end

  it "grava os ajustes do local" do
    patch "/saude-aparelhos/ajustes", params: { site_id: site.id, settings: { battery_low_pct: "35", battery_notify: "0", offline_hours: "8" } }
    expect(flash[:notice]).to eq("Ajustes do local salvos.")
    expect(within(tenant) { Diagnostics.settings(site.reload) }).to include("battery_low_pct" => 35, "battery_notify" => false, "offline_hours" => 8)
    get "/saude-aparelhos", params: { site_id: site.id }
    expect(response.body).not_to include("Teste Tomada") # 3 h < 8 h
  end

  it "esconde IP de quem não cadastra e barra quem não é técnico" do
    morador = create(:user, tenant: tenant, role: "member")
    within(tenant) { create(:site_membership, site: site, user: morador, role: "resident") }
    sign_in(morador)
    get "/saude-aparelhos"
    expect(response).to redirect_to("/locais")
    post "/saude-aparelhos/silenciar", params: { site_id: site.id, ref: "offline:#{tomada.id}", days: 7 }
    expect(within(tenant) { Diagnostics.snoozes(site.reload) }).to be_empty
  end

  it "entra no menu de Configurações e na Saúde do sistema" do
    get "/configuracoes/saude"
    expect(response.body).to include("Saúde dos aparelhos", "/saude-aparelhos?site_id=#{site.id}")
    get "/locais/#{site.id}/dispositivos"
    expect(response.body).to include("/saude-aparelhos?site_id=#{site.id}")
  end

  it "abre no app pelo AppScreen com reparos como formulários" do
    get "/api/v1/screen", params: { path: "/saude-aparelhos?site_id=#{site.id}" }, headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    page = response.parsed_body.dig("data", "page")
    expect(page["title"]).to eq("Saúde dos aparelhos")
    text = page.to_json
    expect(text).to include("Teste Tomada", "/saude-aparelhos/reparar", "/saude-aparelhos/silenciar")
  end
end
