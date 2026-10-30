require "rails_helper"

RSpec.describe "Leitura periódica na web" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:device) { within(tenant) { create(:device, site: site, driver: "tuya_local", name: "Tomada") } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  it "Atualizar agora põe a leitura na fila; intervalo editável em minutos" do
    sign_in
    get "/dispositivos/#{device.id}"
    expect(response.body).to include("Atualizar agora")
    expect { post "/dispositivos/#{device.id}/atualizar" }.to have_enqueued_job(PollDeviceJob).with(device.id)
    expect(flash[:notice]).to include("Leitura pedida")
    get "/dispositivos/#{device.id}/editar"
    expect(response.body).to include("Ler o estado a cada (minutos)", 'value="30"')
    patch "/dispositivos/#{device.id}", params: { device: { poll_min: "0" } }
    expect(within(tenant) { device.reload.poll_s }).to eq(0)

    mqtt = within(tenant) { create(:device, site: site, driver: "mqtt") }
    post "/dispositivos/#{mqtt.id}/atualizar"
    expect(flash[:alert]).to include("não tem leitura")

    integration = within(tenant) { site.integrations.create!(driver: "alexa", name: "Alexa") }
    get "/locais/#{site.id}/integracoes"
    expect(response.body).to include("Sincroniza sozinha a cada 30 min")
    patch "/integracoes/#{integration.id}", params: { integration: { poll_min: "60" } }
    expect(within(tenant) { integration.reload.poll_s }).to eq(3600)
    patch "/integracoes/#{integration.id}", params: { integration: { poll_min: "-1" } }
    expect(flash[:alert]).to be_present
  end

  it "visitante não pede leitura" do
    guest = create(:user, tenant: tenant, role: "member")
    within(tenant) { create(:site_membership, site: site, user: guest, role: "guest") }
    sign_in(guest)
    get "/dispositivos/#{device.id}"
    expect(response.body).not_to include("Atualizar agora")
    expect { post "/dispositivos/#{device.id}/atualizar" }.not_to have_enqueued_job(PollDeviceJob)
  end

  it "o job lê o aparelho" do
    allow(Polling).to receive(:poll_device)
    PollDeviceJob.perform_now(device.id)
    expect(Polling).to have_received(:poll_device).with(device.id, reconnect: false)
  end
end
