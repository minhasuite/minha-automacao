require "rails_helper"

RSpec.describe "Reconectar e erro da leitura (F8c)" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  it "Tuya: acha a versão que responde, grava e limpa o erro" do
    fake = FakeTuyaDevice.new(version: "3.5")
    device = create(:device, site: site, driver: "tuya_local", external_id: "abc", credential: FakeTuyaDevice::KEY, last_error: "velho",
                             address: { "host" => "127.0.0.1", "port" => fake.port, "version" => "3.5" })
    relay = create(:point, device: device, address: { "dps" => "1" })
    fake.state["1"] = true
    expect(Polling.poll_device(device.id, reconnect: true)).to be true
    expect(relay.reload.value).to be true
    expect(device.reload).to have_attributes(last_error: nil, address: include("version" => "3.5"))
  ensure
    fake&.stop
  end

  it "nenhuma versão responde: mantém o endereço, grava o erro e marca indisponível" do
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    device = create(:device, site: site, driver: "tuya_local", external_id: "abc", credential: FakeTuyaDevice::KEY,
                             address: { "host" => "127.0.0.1", "port" => port, "version" => "3.3" })
    expect(Polling.poll_device(device.id, reconnect: true)).to be false
    expect(device.reload).to have_attributes(status: "offline", address: include("version" => "3.3"))
    expect(device.last_error).to include("sem conexão")
    expect(device.situation).to eq("error")
  end
end
