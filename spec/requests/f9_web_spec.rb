require "rails_helper"

RSpec.describe "F9: telas (energia, agenda, ação HTTP, saída HTTP)" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:device) { within(tenant) { create(:device, site: site, name: "Quadro") } }
  let!(:power) { within(tenant) { create(:point, device: device, name: "Potência", capability: "measure", unit: "W", value: 500) } }
  let!(:tarifa) { within(tenant) { create(:point, device: device, name: "Tarifa", capability: "setpoint", value: 0.95) } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  before { sign_in }

  it "Sistema: o dono libera endereços internos; membro não" do
    get "/configuracoes/sistema"
    expect(response.body).to include("Saída HTTP", "Endereços internos liberados")
    patch "/configuracoes/sistema", params: { http_allow: "192.168.68.0/24\nmeu-gestor.local" }
    expect(tenant.reload.http_allow).to eq(%w[192.168.68.0/24 meu-gestor.local])
    member = create(:user, tenant: tenant, role: "member")
    sign_in(member)
    patch "/configuracoes/sistema", params: { http_allow: "" }
    expect(tenant.reload.http_allow.size).to eq(2)
  end

  it "painel: adiciona o widget de energia pelo editor e mostra consumo e custo" do
    d = within(tenant) { Dashboard.ensure_for(site).first }
    get "/paineis/#{d.id}/editar"
    expect(response.body).to include("Consumo e custo", "Dia de corte", "Tarifa fixa", "Comparar com o período anterior")
    patch "/paineis/#{d.id}/rascunho", params: { op: "add_view", title: "Energia" }
    view = within(tenant) { d.reload.draft["views"].last["id"] }
    patch "/paineis/#{d.id}/rascunho", params: { op: "add_section", view_id: view, title: "Conta de luz" }
    section = within(tenant) { d.reload.draft["views"].last["sections"].first["id"] }
    patch "/paineis/#{d.id}/rascunho", params: { op: "add_widget", target: section, view_id: view,
                                                 widget: { type: "energy", binds: [ "", power.id ], period: "cycle", cycle_day: "10", tariff: "", tariff_point: tarifa.id, goal: "300", compare: "1" } }
    w = within(tenant) { d.reload.draft["views"].last["sections"].first["widgets"].last }
    expect(w).to include("type" => "energy", "binds" => [ power.id ], "period" => "cycle", "cycle_day" => 10, "tariff_point" => tarifa.id, "goal" => 300, "compare" => true)
    expect(w).not_to have_key("tariff")
    get "/paineis/#{d.id}", params: { rascunho: 1, view: view }
    expect(response.body).to include("Consumo e custo", "R$", "kWh", "dw-bars")
  end

  it "integração Google Agenda (ICS) pelo assistente e retorno OAuth com state assinado" do
    get "/locais/#{site.id}/integracoes"
    expect(response.body).to include("Google Agenda / ICS")
    get "/locais/#{site.id}/integracoes/nova", params: { tipo: "calendar" }
    expect(response.body).to include("Link iCal", "Endereço secreto no formato iCal", "Conta Google")
    url = "https://calendar.google.com/calendar/ical/pt-br.brazilian%23holiday%40group.v.calendar.google.com/public/basic.ics"
    stub_request(:get, url).to_return(body: "BEGIN:VCALENDAR\r\nX-WR-CALNAME:Feriados no Brasil\r\nBEGIN:VEVENT\r\nDTSTART;VALUE=DATE:#{(Date.current + 2).strftime('%Y%m%d')}\r\nSUMMARY:Feriado\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
    post "/locais/#{site.id}/integracoes", params: { tipo: "calendar", integration: { mode: "ics", name: "Feriados", urls: url } }
    expect(response).to redirect_to("/locais/#{site.id}/integracoes")
    expect(flash[:notice]).to include("1 agenda(s), 1 evento(s)")
    integration = within(tenant) { Integration.sole }
    point = within(tenant) { site.points.find_by!(capability: "calendar") }
    expect(point.name).to eq("Feriados no Brasil")
    get "/integracoes/#{integration.id}/conectar"
    expect(response.body).to include("Deixe vazio para manter")

    get "/integracoes/oauth/retorno", params: { state: "lixo", code: "x" }
    expect(response).to redirect_to("/")
    state = Integrations.oauth_state(integration)
    get "/integracoes/oauth/retorno", params: { state: state, error: "access_denied" }
    expect(flash[:alert]).to eq("Login cancelado.")
    get "/integracoes/oauth/retorno", params: { state: state, code: "x" }
    expect(flash[:alert]).to include("não usa login externo")

    stub_const("ENV", ENV.to_h.merge("GOOGLE_CLIENT_ID" => "cid", "GOOGLE_CLIENT_SECRET" => "sec"))
    post "/locais/#{site.id}/integracoes", params: { tipo: "calendar", integration: { mode: "google" } }
    google = within(tenant) { Integration.where.not(id: integration.id).sole }
    follow_redirect!
    expect(response.body).to include("Entrar com o Google", "accounts.google.com", CGI.escape("http://www.example.com/integracoes/oauth/retorno"))
    stub_request(:post, "https://oauth2.googleapis.com/token").to_return(body: { access_token: "A", refresh_token: "R", expires_in: 3600 }.to_json)
    stub_request(:get, /calendarList/).to_return(body: { items: [] }.to_json)
    get "/integracoes/oauth/retorno", params: { state: Integrations.oauth_state(google), code: "C" }
    expect(flash[:notice]).to include("Conta Google conectada")
  end

  it "editor de automação mostra a ação Chamar HTTP com o segredo mascarado" do
    a = within(tenant) { Automation.create!(site: site, name: "Avisar vendas") }
    patch "/automacoes/#{a.id}/rascunho", params: { op: "add", target: "actions", type: "http" }
    patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "actions.0", block: { method: "POST", url: "https://vendas.exemplo.com/hook", secret: "segredo-1", headers: "Authorization: Bearer {{ secret }}" } }
    node = within(tenant) { a.reload.draft["actions"].last }
    expect(node["secret"]).to be_a(Hash)
    get "/automacoes/#{a.id}/editar"
    expect(response.body).to include("Chamar HTTP / webhook", "Guardado (cifrado)", "guardado")
    expect(response.body).not_to include("segredo-1")
  end
end
