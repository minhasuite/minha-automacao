require "rails_helper"

# Pacote 1: Broadlink IR/RF contra um aparelho falso em UDP local que fala o
# protocolo (hello, auth com troca de chave, enviar, aprender, sensores).
# Registro por stub_const: o núcleo não muda para receber a integração.
RSpec.describe "Pacote 1: Broadlink" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:fake) { FakeBroadlink.new }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  before do
    stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[BroadlinkPlugin])
    stub_const("Drivers::REGISTRY", Drivers::REGISTRY.merge("broadlink" => "Drivers::Broadlink"))
    stub_const("Polling::DEVICES", Polling::DEVICES.merge("broadlink" => "Drivers::Broadlink"))
  end

  after { fake.stop }

  def client = Broadlink::Client.new(host: "127.0.0.1", port: fake.port, mac: "a1b2c3d4e5f6", devtype: 0x6026).auth!

  it "hello, auth com a chave da sessão, envio, aprendizado e sensores" do
    expect(Broadlink.hello("127.0.0.1", fake.port)).to include("devtype" => 0x6026, "mac" => "a1b2c3d4e5f6", "name" => "RM da sala", "locked" => false)
    c = client
    c.send_data("\x01\x02".b)
    expect(fake.sent).to eq([ "\x01\x02".b ])
    expect(c.learn(timeout: 2, interval: 0.01)).to eq("\x26\x00\x05\x00\x11\x22\x33".b)
    expect(c.sensors).to eq("temperature" => 25.5, "humidity" => 60.0)
  end

  it "aprender sem botão apertado termina vazio no tempo" do
    expect(Broadlink::Client.new(host: "127.0.0.1", port: fake.port, mac: "a1b2c3d4e5f6", devtype: 0x6026).auth!.check_data).to be_nil
  end

  it "descoberta só lista quem respondeu ao hello" do
    list = Broadlink.discover(timeout: 0.5, targets: [ "127.0.0.1" ], port: fake.port)
    expect(list).to eq([ { "host" => "127.0.0.1", "devtype" => 0x6026, "mac" => "a1b2c3d4e5f6", "name" => "RM da sala", "locked" => false } ])
    allow(Broadlink).to receive(:discover).and_return(list)
    expect(Integrations::BroadlinkPlugin.discovers?).to be(true)
    expect(Integrations::BroadlinkPlugin.discover).to eq([ { "name" => "RM da sala", "host" => "127.0.0.1", "port" => 80, "txt" => { "md" => "RM4 Pro" } } ])
    expect(Integration.count).to eq(0)
  end

  it "integração: lê o RM4 Pro, adota com Controle e sensores, aprende e manda pelo comando do ponto" do
    o = Integrations::BroadlinkPlugin.setup(site, ActionController::Parameters.new(host: "127.0.0.1", port: fake.port.to_s))
    expect(o.to).to eq(:found)
    Integrations.adopt!(o.integration, { "a1b2c3d4e5f6" => "" })
    device = site.devices.find_by!(driver: "broadlink", external_id: "a1b2c3d4e5f6")
    expect(device).to have_attributes(model: "RM4 Pro", name: "RM da sala")
    expect(device.points.pluck(:name, :capability)).to contain_exactly([ "Controle", "remote" ], [ "Temperatura", "measure" ], [ "Umidade", "measure" ])

    Drivers::Broadlink.poll(device)
    expect(device.points.find_by!(name: "Temperatura").value).to eq(25.5)

    remote = device.points.find_by!(capability: "remote")
    Points::Command.call(remote, "learn", "Ligar TV", source: "web")
    perform_enqueued_jobs
    expect(remote.reload.address["codes"]).to eq("Ligar TV" => Base64.strict_encode64("\x26\x00\x05\x00\x11\x22\x33".b))

    cmd = Points::Command.call(remote, "send", "Ligar TV", source: "web")
    perform_enqueued_jobs
    expect(cmd.reload.status).to eq("confirmed")
    expect(fake.sent.last).to eq("\x26\x00\x05\x00\x11\x22\x33".b)
    expect(remote.reload.value).to eq("buttons" => 1, "last" => "Ligar TV")
  end

  it "aparelho bloqueado ou fora do ar vira aviso, não exceção" do
    locked = FakeBroadlink.new(locked: true)
    o = Integrations::BroadlinkPlugin.setup(site, ActionController::Parameters.new(host: "127.0.0.1", port: locked.port.to_s))
    expect(Broadlink.hello("127.0.0.1", locked.port)["locked"]).to be(true)
    expect(o.alert).to match(/bloqueado/)
    locked.stop

    dead = UDPSocket.new.tap { |s| s.bind("127.0.0.1", 0) }
    port = dead.addr[1]
    dead.close
    allow(Broadlink).to receive(:hello).and_raise(Broadlink::Error, "O aparelho não respondeu em 127.0.0.1.")
    expect(Integrations::BroadlinkPlugin.setup(site, ActionController::Parameters.new(host: "127.0.0.1", port: port.to_s)).alert).to match(/não respondeu/)
  end
end
