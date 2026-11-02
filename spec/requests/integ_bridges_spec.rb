require "rails_helper"

# integ: tela da ponte Matter (o que expor, QR, chave) e a API do serviço.
RSpec.describe "Ponte Matter (integ)" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:light) do
    within(tenant) do
      d = create(:device, site: site, name: "Sala", driver: "virtual")
      create(:point, device: d, site: site, name: "Luz da sala", capability: "onoff", value: false)
    end
  end
  let!(:gate) { within(tenant) { create(:point, device: light.device, site: site, name: "Portão", capability: "gate", risk: "critical", value: "closed") } }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def sign_in = post("/entrar", params: { email: user.email, password: "12345678" })
  def key(scopes = %w[read command]) = { "X-Api-Key" => within(tenant) { ServiceApiKey.issue(user, name: "Teste ponte", scopes: scopes, site_ids: [ site.id ]).last } }
  def exposures = within(tenant) { BridgeExposure.where(site: site).to_a }

  it "tela: lista o que a ponte entende, expõe com nome, pede confirmação no crítico e gera a chave" do
    sign_in
    get "/locais/#{site.id}/pontes/matter"
    expect(response.body).to include("Ponte Matter", "Luz da sala", "Portão", "Crítico", "Serviço fora do ar", "Gerar chave")

    patch "/locais/#{site.id}/pontes/matter", params: { items: { light.id => { exposed: "1", name: "Luz" }, gate.id => { exposed: "1" } } }
    expect(flash[:alert]).to match(/confirmação/)
    expect(exposures.map(&:point_id)).to eq([ light.id ])
    patch "/locais/#{site.id}/pontes/matter", params: { items: { gate.id => { exposed: "1", confirm: "1" } } }
    expect(exposures.size).to eq(2)
    patch "/locais/#{site.id}/pontes/matter", params: { items: { light.id => { exposed: "0" } } }
    expect(exposures.map(&:point_id)).to eq([ gate.id ])

    post "/locais/#{site.id}/pontes/matter/chave"
    expect(response.body).to match(/svc_[\w-]{20,}/)
    within(tenant) { expect(ServiceApiKey.last).to have_attributes(scopes: %w[read command], site_ids: [ site.id ]) }
  end

  it "serviço: lê os expostos, manda a situação (QR na tela) e o comando; chave só de leitura não comanda" do
    within(tenant) { BridgeExposure.create!(site: site, point: light, bridge: "matter", name: "Luz") }
    headers = key

    get "/api/v1/bridges/matter", headers: headers
    expect(response.parsed_body.dig("data", "devices")).to contain_exactly(include("id" => light.id, "type" => "on_off_light", "name" => "Luz",
                                                                                   "state" => { "onOff" => { "onOff" => false } }))

    put "/api/v1/bridges/matter/status", headers: headers, params: { qr: "MT:Y.K90AFN00KA0648G00", manual: "34970112332", commissioned: false }, as: :json
    expect(response).to have_http_status(:no_content)
    sign_in
    get "/locais/#{site.id}/pontes/matter"
    expect(response.body).to include("Esperando pareamento", "3497-011-2332", "<svg")

    post "/api/v1/bridges/matter/commands", headers: headers, params: { point_id: light.id, attribute: "onOff.onOff", value: true }, as: :json
    expect(response).to have_http_status(:accepted)
    expect(light.reload.value).to be true

    post "/api/v1/bridges/matter/commands", headers: key(%w[read]), params: { point_id: light.id, attribute: "onOff.onOff", value: false }, as: :json
    expect(response).to have_http_status(:forbidden)
    other = within(tenant) { create(:point, device: light.device, site: site, name: "Abajur", capability: "onoff") }
    post "/api/v1/bridges/matter/commands", headers: headers, params: { point_id: other.id, attribute: "onOff.onOff", value: true }, as: :json
    expect(response).to have_http_status(:unprocessable_content) # não exposto
    get "/api/v1/bridges/nada", headers: headers
    expect(response).to have_http_status(:not_found)
  end
end
