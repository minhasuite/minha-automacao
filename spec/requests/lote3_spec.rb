require "rails_helper"

# Lote 3: telas da câmera RTSP/ONVIF, do login próprio da Alexa e do editor
# da ação "Falar".
RSpec.describe "Lote 3: telas de câmera e Alexa" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  before { sign_in }

  it "câmera RTSP: formulário, URL com senha vira senha cifrada e a câmera aparece nos encontrados" do
    get "/locais/#{site.id}/integracoes/nova", params: { tipo: "camera" }
    expect(response.body).to include("Endereço RTSP", "Porta ONVIF", "ONVIF")
    post "/locais/#{site.id}/integracoes", params: { tipo: "camera", integration: { mode: "rtsp", url: "" } }
    expect(response).to have_http_status(:unprocessable_content)

    post "/locais/#{site.id}/integracoes", params: { tipo: "camera", integration: { mode: "rtsp", name: "Garagem", url: "rtsp://admin:s3nh%40@10.0.0.30/stream2" } }
    cam = within(tenant) { Integration.find_by!(driver: "camera") }
    expect(response).to redirect_to("/integracoes/#{cam.id}/encontrados")
    expect(cam.secrets).to eq("password" => "s3nh@")
    follow_redirect!
    expect(response.body).to include("Garagem")
    expect(response.body).not_to include("s3nh")
    get "/integracoes/#{cam.id}/conectar"
    expect(response.body).to include("Deixe vazio para manter o endereço guardado")
  end

  it "Alexa: escolhe o país, abre o link da Amazon e cola o endereço final" do
    get "/locais/#{site.id}/integracoes/nova", params: { tipo: "alexa" }
    expect(response.body).to include("Amazon do país da conta", "amazon.com.br", "Cookies da sessão")
    post "/locais/#{site.id}/integracoes", params: { tipo: "alexa", integration: { domain: "amazon.com.br" } }
    alexa = within(tenant) { Integration.find_by!(driver: "alexa") }
    expect(response).to redirect_to("/integracoes/#{alexa.id}/conectar")
    expect(alexa.status).to eq("pending")
    get "/integracoes/#{alexa.id}/conectar"
    expect(response.body).to include("Abrir o login da Amazon", "https://www.amazon.com.br/ap/signin?", "Endereço da página depois de entrar")

    post "/integracoes/#{alexa.id}/conectar", params: { integration: { return_url: "" } }
    expect(flash[:alert]).to include("Cole o endereço")

    stub_request(:post, "https://api.amazon.com/auth/register").to_return(body: {
      "response" => { "success" => { "tokens" => { "bearer" => { "refresh_token" => "R" }, "website_cookies" => [ { "Name" => "csrf", "Value" => "9" } ] } } }
    }.to_json)
    stub_request(:get, "https://alexa.amazon.com.br/api/devices-v2/device?cached=true").to_return(body: { devices: [
      { "accountName" => "Echo Sala", "deviceFamily" => "ECHO", "deviceType" => "A3", "serialNumber" => "S1", "online" => true, "deviceOwnerCustomerId" => "C" }
    ] }.to_json)
    post "/integracoes/#{alexa.id}/conectar", params: { integration: { return_url: "https://www.amazon.com.br/ap/maplanding?openid.oa2.authorization_code=ANabc12345" } }
    expect(response).to redirect_to("/locais/#{site.id}/integracoes")
    expect(alexa.reload).to have_attributes(status: "ok")
    within(tenant) { expect(Device.find_by!(name: "Echo Sala").area).to be_nil }

    stub_request(:post, "https://api.amazon.com/auth/register").to_return(body: { "response" => { "error" => { "code" => "X" } } }.to_json)
    Alexa::Auth.start!(alexa)
    post "/integracoes/#{alexa.id}/conectar", params: { integration: { return_url: "ANabc12345" } }
    expect(flash[:alert]).to include("Não deu para entrar")
    expect(alexa.reload).to be_auth_error
  end

  it "editor: a ação Falar só oferece canais de fala" do
    echo = within(tenant) do
      i = Integration.create!(site: site, driver: "alexa", name: "Alexa")
      d = create(:device, site: site, name: "Echo Sala", driver: "alexa", integration: i)
      create(:point, device: d, site: site, name: "Falar", capability: "speaker")
    end
    a = within(tenant) { Automation.create!(site: site, name: "Teste falar", kind: "automation", mode: "single") }
    within(tenant) { a.update!(draft: { "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "speak", "channels" => [ "alexa:#{echo.id}" ], "message" => "Oi" } ] }) }
    get "/automacoes/#{a.id}/editar"
    expect(response.body).to include("Onde falar", "Falar na Echo Sala", "Com o som de anúncio")
    expect(response.body.scan("Push no celular").size).to be <= 1 # o campo de canais da ação Falar não oferece push
  end
end
