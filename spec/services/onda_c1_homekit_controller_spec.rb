require "rails_helper"

# ondaC1 (C5): o MA como controlador HomeKit (HAP nativo em Ruby). O
# acessório é de mentira mas fala o protocolo de verdade por TCP em
# 127.0.0.1 (FakeHapAccessory): SRP-6a, pair-verify, sessão ChaCha20.
RSpec.describe "HomeKit controlador (ondaC1, C5)" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:acc) { FakeHapAccessory.new }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }
  after { acc.stop }

  def form(h) = ActionController::Parameters.new(h)
  def run(point, command, value = nil) = ExecuteCommandJob.perform_now(Points::Command.call(point, command, value, source: "web").id)

  it "TLV8 em pedaços de 255 e o tipo curto do HAP" do
    long = "x" * 600
    expect(Hap::Tlv.decode(Hap::Tlv.encode([ [ 5, long ], [ 6, 3 ] ]))).to eq(5 => long, 6 => "\x03".b)
    expect(Hap.short_type("00000025-0000-1000-8000-0026BB765291")).to eq("25")
    expect(Hap.short_type("0000008A-0000-1000-8000-0026BB765291")).to eq("8A")
  end

  it "pareia pelo código, lista os acessórios da ponte, lê e comanda pela sessão cifrada" do
    o = Integrations::HomekitPlugin.setup(site, form(host: "127.0.0.1", port: acc.port, code: "031-45-154"))
    expect(o.alert).to be_nil
    i = o.integration
    expect(i.secrets["pairing"]).to include("accessory_ltpk")
    expect(i.found.map { |e| e["name"] }).to eq([ "Teste Lâmpada", "Teste Sensor" ])
    Integrations.adopt!(i, i.found.to_h { |e| [ e["id"], "" ] })
    lamp = site.devices.find_by!(external_id: "homekit:#{FakeHapAccessory::ID}:1")
    expect(lamp).to have_attributes(driver: "homekit", manufacturer: "Teste Fabricante")
    pts = lamp.points.index_by(&:name)
    expect(pts["Liga/desliga"]).to have_attributes(capability: "onoff", value: false)
    expect(pts["Brilho"].value).to eq(40)
    temp = site.devices.find_by!(external_id: "homekit:#{FakeHapAccessory::ID}:2").points.first
    expect(temp).to have_attributes(capability: "measure", value: 21.5, writable: false)

    run(pts["Liga/desliga"], "on")
    run(pts["Brilho"], "set", 75)
    expect(acc.puts).to eq([ { "aid" => 1, "iid" => 10, "value" => true }, { "aid" => 1, "iid" => 11, "value" => 75 } ])
    acc.values[[ 2, 10 ]] = 23.0
    Drivers::Homekit.poll(temp.device)
    expect(temp.reload.value).to eq(23.0)
  end

  it "código errado não pareia e acessório trocado é recusado na verificação" do
    bad = Integrations::HomekitPlugin.setup(site, form(host: "127.0.0.1", port: acc.port, code: "111-22-333"))
    expect(bad.alert).to match(/código|recusou/i)
    expect(Integrations::HomekitPlugin.setup(site, form(host: "127.0.0.1", code: "12")).alert).to match(/8 dígitos/)

    good = Integrations::HomekitPlugin.setup(site, form(host: "127.0.0.1", port: acc.port, code: "03145154")).integration
    pairing = JSON.parse(good.secrets["pairing"]).merge("accessory_ltpk" => OpenSSL::PKey.generate_key("ED25519").raw_public_key.unpack1("H*"))
    expect { Hap::Client.open("127.0.0.1", acc.port, pairing, &:accessories) }.to raise_error(Hap::Error, /não é o que foi pareado/)
  end
end
