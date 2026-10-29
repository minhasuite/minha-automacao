require "rails_helper"

RSpec.describe "Xiaomi MIoT (robô aspirador)" do
  let(:token) { [ FakeMiioDevice::TOKEN ].pack("H*") }

  describe Miio::Protocol do
    it "monta e lê um quadro cifrado (cabeçalho, MD5 e AES)" do
      frame = described_class.encode(token, did: 7, stamp: 100, payload: '{"id":1,"method":"x"}')
      expect(frame.unpack("nnNNN")).to eq([ 0x2131, frame.bytesize, 0, 7, 100 ])
      expect((frame.bytesize - 32) % 16).to eq(0)
      expect(described_class.decode(token, frame)).to eq(did: 7, stamp: 100, payload: '{"id":1,"method":"x"}')
    end

    it "chave e iv derivados do token (MD5)" do
      key, iv = described_class.key_iv(token)
      expect(key).to eq(Digest::MD5.digest(token))
      expect(iv).to eq(Digest::MD5.digest(key + token))
    end

    it "hello: 32 bytes e resposta sem dados" do
      expect(described_class::HELLO.bytesize).to eq(32)
      reply = [ 0x2131, 32, 0, 99, 5 ].pack("nnNNN") + ("\x00".b * 16)
      expect(described_class.decode(token, reply)).to eq(did: 99, stamp: 5, payload: nil)
    end

    it "recusa quadro com token errado, curto ou com tamanho trocado" do
      frame = described_class.encode(token, did: 7, stamp: 1, payload: "{}")
      expect { described_class.decode("x" * 16, frame) }.to raise_error(described_class::Error, /checksum/)
      expect { described_class.decode(token, "abc") }.to raise_error(described_class::Error, /curto/)
      expect { described_class.decode(token, "#{frame}x") }.to raise_error(described_class::Error, /inválido/)
      expect { described_class.decrypt(token, "y" * 16) }.to raise_error(described_class::Error)
    end
  end

  describe Miio::Client do
    it "faz o hello e lê propriedades (só as que vieram com code 0)" do
      fake = FakeMiioDevice.new([ 2, 2 ] => 2, [ 3, 1 ] => 96)
      client = described_class.new(host: "127.0.0.1", port: fake.port, token: FakeMiioDevice::TOKEN)
      expect(client.get_properties([ [ 2, 2 ], [ 3, 1 ], [ 9, 9 ] ])).to eq([ 2, 2 ] => 2, [ 3, 1 ] => 96)
      expect(client.did).to eq(FakeMiioDevice::DID)
    ensure
      fake&.stop
    end

    it "aparelho calado vira erro depois das tentativas" do
      fake = FakeMiioDevice.new
      fake.silent = true
      client = described_class.new(host: "127.0.0.1", port: fake.port, token: FakeMiioDevice::TOKEN, timeout: 0.1, retries: 1)
      expect { client.call("get_properties", []) }.to raise_error(described_class::Error, /não respondeu/)
    ensure
      fake&.stop
    end
  end

  describe Drivers::XiaomiMiot do
    let(:tenant) { create(:tenant) }
    let(:site) { create(:site) }
    let(:rooms) { [ { "id" => 5, "name" => "Sala de estar" }, { "id" => 7, "name" => "Suíte KH" }, { "id" => 45, "name" => "Cozinha" } ] }
    let(:fake) do
      FakeMiioDevice.new([ 2, 2 ] => 2, [ 2, 4 ] => 4, [ 2, 9 ] => 2, [ 2, 10 ] => 3, [ 2, 74 ] => 3, [ 2, 8 ] => 1, [ 3, 1 ] => 96,
                         [ 2, 66 ] => '{"ts":1,"fault":[0]}', [ 2, 6 ] => 3400, [ 2, 7 ] => 2640, [ 12, 1 ] => 80, [ 9, 1 ] => 47)
    end
    let(:device) do
      Miio::Import.call(site, "did" => FakeMiioDevice::DID, "host" => "127.0.0.1", "token" => FakeMiioDevice::TOKEN,
                              "model" => "xiaomi.vacuum.d109gl", "name" => "Robô aspirador", "rooms" => rooms)
      site.devices.find_by!(driver: "xiaomi_miot").tap { |d| d.update!(address: d.address.merge("port" => fake.port)) }
    end
    let(:robot) { device.points.find_by!(capability: "vacuum") }

    around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }
    after { fake.stop }

    def by_name(name) = device.points.find_by!(name: name).reload

    it "importa o robô com cômodos e ações e é idempotente" do
      expect(device.credential).to eq(FakeMiioDevice::TOKEN)
      expect(robot.address["rooms"].pluck("id")).to eq([ 5, 7, 45 ])
      expect(robot.address["actions"]).to include("clean_rooms" => [ 2, 16 ], "home" => [ 2, 3 ])
      count = device.points.count
      r = Miio::Import.call(site, "did" => FakeMiioDevice::DID, "host" => "10.0.0.9", "rooms" => rooms.first(1))
      expect(r).to eq(device: 0, points: 0)
      expect(device.points.count).to eq(count)
      expect(robot.reload.address["rooms"].size).to eq(1)
      expect(device.reload.address["host"]).to eq("10.0.0.9")
    end

    it "lê o estado e traduz códigos, escala e erro" do
      described_class.poll(device)
      expect(robot.reload.value).to eq("docked")
      expect(by_name("Situação").value).to eq("Carregando")
      expect(by_name("Modo").value).to eq("Aspirar antes do pano")
      expect(by_name("Água do pano").value).to eq("Nível 3")
      expect(by_name("Bateria").value).to eq(96)
      expect(by_name("Área da limpeza").value).to eq(34.0)
      expect(by_name("Duração da limpeza").value).to eq(44.0)
      expect(by_name("Erro").value).to be false
      expect(by_name("Escova principal").value).to eq(80)
      expect(device.reload.status).to eq("online")
    end

    it "comandos simples viram ação MIoT; pausado, iniciar continua" do
      driver = described_class.new
      driver.execute(robot, "home", nil)
      expect(fake.calls.find { |c| c["method"] == "action" }["params"]).to include("siid" => 2, "aiid" => 3, "in" => [])
      robot.update!(value: "paused")
      driver.execute(robot, "start", nil)
      expect(fake.calls.select { |c| c["method"] == "action" }.last["params"]).to include("aiid" => 8)
    end

    it "limpar cômodos grava só os ajustes que mudaram e manda os ids como texto" do
      described_class.poll(device)
      command = Points::Command.call(robot, "clean_rooms", { "rooms" => %w[5 45], "mode" => "Só aspirar", "suction" => "Normal" }, source: "web")
      expect(command.value).to eq("rooms" => [ 5, 45 ], "mode" => "Só aspirar", "suction" => "Normal")
      perform_enqueued_jobs
      expect(command.reload.status).to eq("confirmed")
      set = fake.calls.find { |c| c["method"] == "set_properties" }["params"]
      expect(set.map { |p| [ p["siid"], p["piid"], p["value"] ] }).to eq([ [ 2, 4, 1 ] ])
      action = fake.calls.find { |c| c["method"] == "action" }["params"]
      expect(action).to include("siid" => 2, "aiid" => 16, "in" => [ "5,45" ])
      expect(by_name("Modo").value).to eq("Só aspirar")
    end

    it "ajuste sozinho (seleção) grava a propriedade" do
      described_class.poll(device)
      described_class.new.execute(by_name("Caminho"), "select", "Rápido")
      expect(fake.props[[ 2, 74 ]]).to eq(1)
      expect(by_name("Caminho").value).to eq("Rápido")
    end

    it "valida cômodos e ajustes antes de criar o comando" do
      expect { Points::Command.call(robot, "clean_rooms", { "rooms" => [] }, source: "web") }.to raise_error(Points::Command::Error, /cômodo/)
      expect { Points::Command.call(robot, "clean_rooms", { "rooms" => [ 99 ] }, source: "web") }.to raise_error(Points::Command::Error, /desconhecido/)
      expect { Points::Command.call(robot, "clean_rooms", { "rooms" => [ 5 ], "water" => "Muita" }, source: "web") }.to raise_error(Points::Command::Error, /Água/)
      expect { Points::Command.call(robot, "dance", nil, source: "web") }.to raise_error(Points::Command::Error)
      expect(Command.count).to eq(0)
    end

    it "sem resposta: o leitor marca os pontos indisponíveis" do
      fake.silent = true
      allow(described_class).to receive(:client_for).and_wrap_original do |m, d|
        m.call(d).tap { |c| c.instance_variable_set(:@timeout, 0.1) && c.instance_variable_set(:@retries, 0) }
      end
      device
      Miio::Poller.tick
      expect(robot.reload.quality).to eq("unavailable")
      expect(device.reload.status).to eq("offline")
    end

    it "sem host ou token não tenta" do
      device.update!(credential: nil)
      expect { described_class.client_for(device) }.to raise_error(described_class::Error, /token/)
    end
  end
end
