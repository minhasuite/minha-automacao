require "rails_helper"

# integ2: as integrações novas aparecem no catálogo e cada uma tem o formulário de adicionar.
RSpec.describe "Integrações novas (integ2)" do
  let(:user) { create(:user) }
  let!(:site) { within(user.tenant) { create(:site, name: "Casa") } }

  before { post("/entrar", params: { email: user.email, password: "12345678" }) }

  it "catálogo e formulário de cada tipo" do
    get "/locais/#{site.id}/integracoes"
    expect(response.body).to include("Daikin", "Midea", "LG ThinQ", "Inversor solar (SunSpec / Modbus)", "Growatt", "IKEA Dirigera", "Sonos", "Govee",
                                     "Z-Wave JS", "Proxy Bluetooth (ESPHome)")
    get "/locais/#{site.id}/integracoes", params: { q: "ar-condicionado" }
    expect(response.body).to include("Daikin", "Midea", "LG ThinQ")

    { "daikin" => "BRP069", "midea" => "Id do aparelho", "lg_thinq" => "Token de acesso pessoal", "sunspec" => "Unidade Modbus", "growatt" => "Token da API",
      "dirigera" => "botão de ação", "sonos" => "Uma caixa Sonos", "govee" => "Controle LAN", "zwave_js" => "ws://192.168.0.10:3000",
      "ble_proxy" => "bluetooth_proxy" }.each do |tipo, text|
      get "/locais/#{site.id}/integracoes/nova", params: { tipo: tipo }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(text)
    end
  end
end
