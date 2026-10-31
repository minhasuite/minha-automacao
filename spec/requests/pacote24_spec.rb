require "rails_helper"

RSpec.describe "Pacotes 2 e 4 na web" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:tg_api) { "https://api.telegram.org/bot123:SEGREDO" }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })
  def ok(result) = { status: 200, body: { ok: true, result: result }.to_json }

  before { allow(SafeHttp).to receive(:lookup).and_return([ "93.184.216.34" ]) }

  it "medidor por ciclo pelo formulário: cria, mostra o resumo, edita e conta o consumo" do
    sign_in
    src = within(tenant) { create(:point, device: create(:device, site: site), capability: "measure", unit: "kWh").tap { |p| p.report!(10) } }
    post "/locais/#{site.id}/helpers", params: { tipo: "utility_meter", helper: { name: "Energia do mês", source: src.id, cycle: "month", day: "12", tariffs_text: "Ponta, Fora" } }
    expect(response).to redirect_to("/locais/#{site.id}/helpers")
    get "/locais/#{site.id}/helpers"
    expect(response.body).to include("Energia do mês", "Mensal · fecha dia 12", "tarifas: Ponta, Fora")
    m = within(tenant) { site.points.find_by!(helper: "utility_meter") }
    get "/helpers/#{m.id}/editar"
    expect(response.body).to include("Dia de fechamento", "Ponta, Fora")
    within(tenant) { src.report!(15) }
    expect(within(tenant) { m.reload.value }).to eq(5.0)
  end

  it "Telegram: cria pelo assistente, acha o chat, envia teste; webhook sem segredo = 403, desconhecido = 404" do
    sign_in
    stub_request(:post, "#{tg_api}/getMe").to_return(ok("username" => "casa_bot"))
    stub_request(:post, "#{tg_api}/deleteWebhook").to_return(ok(true))
    post "/locais/#{site.id}/integracoes", params: { tipo: "telegram", integration: { token: "123:SEGREDO" } }
    i = within(tenant) { site.integrations.find_by!(driver: "telegram") }
    expect(response).to redirect_to("/integracoes/#{i.id}/conectar")
    expect(within(tenant) { i.settings["user_id"] }).to eq(user.id)

    stub_request(:post, "#{tg_api}/getUpdates").to_return(ok([ { "update_id" => 1, "message" => { "chat" => { "id" => 42, "first_name" => "Ana" } } } ]))
    get "/integracoes/#{i.id}/conectar", params: { find: 1 }
    expect(response.body).to include("Achar meu chat", "Ana", "Usar esta conversa")
    expect(response.body).not_to include("SEGREDO")

    post "/integracoes/#{i.id}/conectar", params: { integration: { chat_id: "42", webhook: "0" } }
    stub_request(:post, "#{tg_api}/sendMessage").to_return(ok({}))
    post "/integracoes/#{i.id}/conectar", params: { integration: { test: "1" } }
    follow_redirect!
    expect(response.body).to include("Mensagem de teste enviada.")

    post "/mensageiros/#{i.id}", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:forbidden)
    post "/mensageiros/#{SecureRandom.uuid}"
    expect(response).to have_http_status(:not_found)
  end
end
