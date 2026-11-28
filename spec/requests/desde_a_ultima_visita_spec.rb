require "rails_helper"

# componentes_ui v1.14.2 (27/11/2026): o "desde a última visita" do Início (web e app).
RSpec.describe "Desde a última visita" do
  let(:user) { create(:user, name: "Dona") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Virtual", driver: "virtual") } }
  let(:gate) { within(tenant) { create(:point, device: device, site: site, key: "garagem.portao", name: "Portão", capability: "contact", data_type: "bool", value: false) } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  before do
    within(tenant) do
      rule = AlertRule.create!(site: site, point: gate, name: "Portão aberto", operator: "eq", value: true, severity: "critical")
      Alert.create!(site: site, alert_rule: rule, point: gate, opened_at: 5.minutes.ago)
    end
  end

  it "a API conta os alertas que abriram desde a visita; data ruim é recusada" do
    get "/api/v1/since_last_visit", params: { since: 1.hour.ago.iso8601 }, headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "items")).to include(include("key" => "alerts", "value" => "1", "label" => "alerta abriu", "tone" => "danger"))
    get "/api/v1/since_last_visit", params: { since: 1.minute.from_now.iso8601 }, headers: auth_headers(user)
    expect(response.parsed_body.dig("data", "items")).to eq([])
    get "/api/v1/since_last_visit", params: { since: "ontem" }, headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "o Início busca o cartão em /desde, que lista o alerta com o link" do
    sign_in
    get "/desde", params: { desde: 1.hour.ago.iso8601 }
    expect(response.body).to include("ss-since", "alerta abriu", "/alertas")
  end

  it "não conta o que é de local que a pessoa não vê" do
    other = create(:user)
    get "/api/v1/since_last_visit", params: { since: 1.hour.ago.iso8601 }, headers: auth_headers(other)
    expect(response.parsed_body.dig("data", "items")).to eq([])
  end
end
