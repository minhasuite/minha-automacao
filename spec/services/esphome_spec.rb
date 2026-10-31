require "rails_helper"

# Pacote 1: ESPHome pela API nativa, contra um aparelho falso local (thread
# com TCPServer) que fala o protocolo sem e com criptografia Noise (o lado
# responder usa o mesmo Esphome::Noise). Registro só por stub_const: o
# núcleo não sabe que o ESPHome existe.
RSpec.describe "Pacote 1: ESPHome" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:key) { Base64.strict_encode64("k" * 32) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  before do
    stub_const("Drivers::REGISTRY", Drivers::REGISTRY.merge("esphome" => "Drivers::Esphome"))
    stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[EsphomePlugin])
    stub_const("Polling::DEVICES", Polling::DEVICES.merge("esphome" => "Drivers::Esphome"))
  end

  def connect(fake, **form)
    Integrations::EsphomePlugin.setup(site, ActionController::Parameters.new(host: "127.0.0.1", port: fake.port, **form))
  end

  def adopt(outcome)
    Integrations.adopt!(outcome.integration, { "AA:BB:CC:DD:EE:FF" => "" })
    site.devices.find_by!(driver: "esphome")
  end

  def point(device, name) = device.points.reload.find_by!(name: name)

  describe Esphome::Noise do
    it "fecha o handshake NNpsk0 e cifra nos dois sentidos" do
      psk = described_class.psk(key)
      a = described_class.new(psk)
      b = described_class.new(psk, initiator: false)
      b.read_first(a.write_first)
      a.read_second(b.write_second)
      expect(b.receiver.decrypt("".b, a.sender.encrypt("".b, "olá".b))).to eq("olá".b)
      expect(a.receiver.decrypt("".b, b.sender.encrypt("".b, "oi".b))).to eq("oi".b)

      c = described_class.new(described_class.psk(Base64.strict_encode64("x" * 32)), initiator: false)
      expect { c.read_first(described_class.new(psk).write_first) }.to raise_error(Esphome::Error, /recusada/)
      expect { described_class.psk("curta") }.to raise_error(Esphome::Error)
    end
  end

  context "sem criptografia" do
    let(:fake) { FakeEsphome.new }

    after { fake.stop }

    it "lê o aparelho, vira pontos pelo mapa, adota e grava o estado" do
      o = connect(fake)
      expect(o.to).to eq(:found)
      entry = o.integration.found.first
      expect(entry).to include("id" => "AA:BB:CC:DD:EE:FF", "kind" => "esphome", "name" => "Sensor da sala", "model" => "esp32dev")
      caps = entry["points"].to_h { |p| [ p["name"], p["capability"] ] }
      expect(caps).to eq("Movimento" => "motion", "Temperatura" => "measure", "Relé" => "onoff", "Luz" => "onoff", "Luz brilho" => "dimmer",
                         "Portão" => "setpoint", "Versão" => "text", "Alvo" => "setpoint", "Reiniciar" => "command")
      expect(site.devices.where(driver: "esphome")).to be_empty # nada entra sozinho

      device = adopt(o)
      expect(device.address).to eq("host" => "127.0.0.1", "port" => fake.port)
      expect(point(device, "Temperatura")).to have_attributes(value: 22.5, unit: "°C", device_class: "temperature", state_class: "measurement")
      expect(point(device, "Movimento").value).to be(true)
      expect(point(device, "Luz brilho").value).to eq(50)
      expect(point(device, "Portão")).to have_attributes(value: 0, risk: "critical")
      expect(point(device, "Versão")).to have_attributes(value: "2026.10.0", writable: false)
      expect(point(device, "Alvo")).to have_attributes(value: 21.0, min: 10, max: 30)
      expect(fake.pongs).to be >= 1
    end

    it "comanda relé, brilho, portão (posição), número e botão" do
      device = adopt(connect(fake))
      run = ->(name, cmd, value = nil) { ExecuteCommandJob.perform_now(Points::Command.call(point(device, name), cmd, value, source: "web").id) }

      run.call("Relé", "on")
      expect(point(device, "Relé").value).to be(true)
      run.call("Luz brilho", "set", 30)
      expect(point(device, "Luz brilho").value).to eq(30)
      run.call("Portão", "set", 100)
      run.call("Alvo", "set", 25)
      run.call("Reiniciar", "press")
      types = fake.commands.map { |t, k, _| [ t, k ] }
      expect(types).to eq([ [ 33, 3 ], [ 32, 4 ], [ 30, 5 ], [ 51, 7 ], [ 62, 8 ] ])
      expect(Proto.float(fake.commands[2][2][5].first)).to eq(1.0) # sem posição: 100 = aberto
      expect(point(device, "Alvo").value).to eq(25.0)
      expect(Command.where(point: point(device, "Reiniciar")).last.status).to eq("confirmed").or eq("sent")
    end

    it "ouvinte em tempo real e leitura periódica" do
      device = adopt(connect(fake))
      Point.where(device: device).update_all(value: nil)
      expect(Esphome::Listener.run_once(device.id, rounds: 7)).to be(true)
      expect(point(device, "Relé").value).to be(false)
      expect(point(device, "Temperatura").value).to eq(22.5)

      Point.where(device: device).update_all(value: nil)
      expect(Polling.poll_device(device.id)).to be(true)
      expect(point(device, "Movimento").value).to be(true)

      fake.stop
      expect(Esphome::Listener.run_once(device.id, rounds: 1)).to be(false)
      expect(point(device, "Relé").quality).to eq("unavailable")
    end

    it "senha errada da API pede Reconfigurar" do
      pw = FakeEsphome.new(password: "certa")
      o = connect(pw, password: "errada")
      expect(o.alert).to match(/Senha da API recusada/)
      expect(o.integration.reload).to be_auth_error
      expect(connect(pw, password: "certa").to).to eq(:found)
    ensure
      pw.stop
    end
  end

  context "com criptografia (Noise)" do
    let(:fake) { FakeEsphome.new(key: key) }

    after { fake.stop }

    it "faz o handshake com a chave e lê o aparelho" do
      o = connect(fake, encryption_key: key)
      expect(o.notice).to match(/1 aparelho/)
      expect(o.integration.secrets).to include("encryption_key" => key)
      device = adopt(o)
      expect(point(device, "Relé").value).to be(false)
      ExecuteCommandJob.perform_now(Points::Command.call(point(device, "Relé"), "toggle", nil, source: "web").id)
      expect(point(device, "Relé").value).to be(true)
    end

    it "chave errada ou sem chave viram aviso claro" do
      expect(connect(fake, encryption_key: Base64.strict_encode64("z" * 32)).alert).to match(/Chave recusada/)
      expect(connect(fake).alert).to match(/usa criptografia/)
    end
  end

  it "o catálogo oferece a busca na rede por mDNS" do
    expect(Integrations::EsphomePlugin.mdns).to eq("_esphomelib._tcp")
    expect(Integrations.plugin("esphome")).to eq(Integrations::EsphomePlugin)
  end
end
