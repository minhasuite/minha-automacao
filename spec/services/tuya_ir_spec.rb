require "rails_helper"

# Pacote 1: hub IR da Tuya (Smart IR, `wnykq`) como controle remoto genérico
# pela rede local: dp 201 manda (send_ir) e aprende (study), dp 202 traz o
# código. Contra o FakeTuyaDevice; nada sai para aparelho real.
RSpec.describe "Pacote 1: IR da Tuya" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:fake) { FakeTuyaDevice.new(version: "3.3", state: { "201" => "", "1" => false }) }
  let(:device) do
    create(:device, site: site, driver: "tuya_local", external_id: "hub1", credential: FakeTuyaDevice::KEY,
                    address: { "host" => "127.0.0.1", "port" => fake.port, "version" => "3.3" })
  end
  let(:remote) do
    create(:point, device: device, site: site, name: "Controle", capability: "remote",
                   address: Tuya::Cloud.remote_points("category" => "wnykq").first["address"].merge("codes" => { "Ligar" => "QUJD" }))
  end

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }
  after { fake.stop }

  it "o mapa dá o Controle ao hub IR e nada aos controles virtuais" do
    expect(Tuya::Cloud.remote_points("category" => "wnykq")).to eq([ { "name" => "Controle", "capability" => "remote", "history" => "none",
                                                                      "address" => { "dps" => "201", "learn_dps" => "202", "key_prefix" => "1", "remote" => "tuya_ir" } } ])
    expect(Tuya::Cloud.remote_points("category" => "infrared_tv")).to eq([])
  end

  it "hub já no local ganha o Controle na varredura, uma vez só" do
    entry = { "points" => Tuya::Cloud.remote_points("category" => "wnykq") }
    expect(Integrations.add_points(device, entry)).to eq(1)
    expect(Integrations.add_points(device.reload, entry)).to eq(0)
  end

  it "envia o botão aprendido pelo dp 201 e o estado do aparelho não pisa no valor do controle" do
    remote
    Points::Command.call(remote, "send", "Ligar", source: "web")
    perform_enqueued_jobs
    sleep 0.1 until fake.state["201"].to_s.include?("send_ir")
    expect(JSON.parse(fake.state["201"])).to eq("control" => "send_ir", "head" => "", "key1" => "1QUJD", "type" => 0, "delay" => 300)
    Drivers::TuyaLocal.report(device, { "201" => "x", "1" => true })
    expect(remote.reload.value).to eq("buttons" => 1, "last" => "Ligar")
  end

  it "aprende: entra em study, guarda o código do dp 202 e sai" do
    remote
    t = Thread.new { ActsAsTenant.with_tenant(tenant) { Drivers::TuyaLocal.new.execute(remote, "learn", "Volume +") } }
    deadline = Time.current + 3
    sleep 0.05 until fake.state["201"].to_s.include?("study") || Time.current > deadline
    fake.push("202" => "Q09ESUdP")
    t.join(5)
    expect(remote.reload.address["codes"]).to eq("Ligar" => "QUJD", "Volume +" => "Q09ESUdP")
    deadline = Time.current + 3
    sleep 0.05 until fake.state["201"].to_s.include?("study_exit") || Time.current > deadline
    expect(fake.state["201"]).to include("study_exit")
  end
end
