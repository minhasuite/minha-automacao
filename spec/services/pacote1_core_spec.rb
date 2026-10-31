require "rails_helper"

# Pacote 1 (núcleo): capacidades `media` e `remote`, `address.supports`,
# widgets de mídia e de controle remoto por plugin, protobuf mínimo, mDNS
# (só lê) e a base dos aparelhos da rede. Tudo provado com plugin falso
# (`stub_const`): estender não muda o núcleo.
RSpec.describe "Pacote 1: núcleo de mídia, controle remoto e descoberta" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:device) { create(:device, site: site, name: "TV da sala", driver: "fake_tv") }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  # Driver falso registrado como um de verdade (o núcleo não sabe quem é).
  let(:fake_driver) do
    Class.new do
      cattr_accessor :calls, default: []
      def execute(point, command, value)
        self.class.calls << [ command, value ]
        point.report!((point.value || {}).merge("state" => command == "pause" ? "paused" : "playing"))
      end
    end
  end

  before do
    stub_const("FakeTvDriver", fake_driver)
    stub_const("Drivers::REGISTRY", Drivers::REGISTRY.merge("fake_tv" => "FakeTvDriver"))
    fake_driver.calls = []
  end

  def media(**attrs)
    create(:point, device: device, site: site, name: "TV", capability: "media", value: { "state" => "playing", "title" => "Jornal", "volume" => 20 }, **attrs)
  end

  describe "capacidade media" do
    it "nasce json gravável e aceita os comandos da mídia" do
      p = media
      expect(p).to have_attributes(data_type: "json", writable: true)
      expect(Points::Command.commands_for(p)).to include("on", "pause", "resume", "next", "volume", "mute", "play_media")
    end

    it "address.supports corta o que o aparelho não faz" do
      p = media(address: { "supports" => %w[pause resume volume_up volume_down] })
      expect(Points::Command.commands_for(p)).to eq(%w[resume pause volume_up volume_down])
      expect { Points::Command.call(p, "volume", 10, source: "web") }.to raise_error(Points::Command::Error, /não vale/)
    end

    it "valida volume, mudo e o que tocar, e passa pelo driver" do
      p = media
      expect { Points::Command.call(p, "volume", 120, source: "web") }.to raise_error(Points::Command::Error, /0 a 100/)
      expect { Points::Command.call(p, "play_media", " ", source: "web") }.to raise_error(Points::Command::Error, /o que tocar/)
      expect(Points::Command.new(p, "mute", nil).tap(&:new_value).value).to be(true)
      expect(Points::Command.new(p, "mute", "false").tap(&:new_value).value).to be(false)

      cmd = Points::Command.call(p, "pause", nil, source: "web")
      ExecuteCommandJob.perform_now(cmd.id)
      expect(fake_driver.calls).to eq([ [ "pause", nil ] ])
      expect(p.reload.value["state"]).to eq("paused")
      expect(ApplicationController.helpers.point_value_text(p)).to eq("Pausada · Jornal")
    end
  end

  describe "controle remoto genérico (Remotes)" do
    let(:transport) do
      Class.new do
        attr_reader :sent
        def learn(_point) = "JgBQAAAB"
        def send_code(_point, code) = (@sent = code)
      end.new
    end
    let(:remote) { create(:point, device: device, site: site, name: "Controle", capability: "remote") }

    it "aprende, guarda, envia e esquece pelo nome do botão" do
      Remotes.execute(transport, remote, "learn", "Ligar TV")
      expect(remote.reload.address["codes"]).to eq("Ligar TV" => "JgBQAAAB")
      expect(remote.value).to eq("buttons" => 1, "last" => "Ligar TV")

      expect { Points::Command.new(remote, "send", "Desligar").new_value }.to raise_error(Points::Command::Error, /não foi aprendido/)
      Points::Command.new(remote, "send", "Ligar TV").new_value
      Remotes.execute(transport, remote, "send", "Ligar TV")
      expect(transport.sent).to eq("JgBQAAAB")

      Remotes.execute(transport, remote, "forget", "Ligar TV")
      expect(remote.reload.address["codes"]).to eq({})
    end

    it "aprender sem código recebido é erro" do
      silent = Class.new { def learn(_p) = nil }.new
      expect { Remotes.execute(silent, remote, "learn", "Volume") }.to raise_error(Remotes::Error, /Nenhum código/)
    end
  end

  describe "widgets de mídia e controle remoto" do
    def resolve(widget)
      definition = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => [ widget ] } ] } ] }
      expect(Dashboards::Schema.errors(definition)).to eq([])
      dashboard = Dashboard.create!(site: site, name: "Sala #{SecureRandom.hex(2)}", definition: definition)
      Dashboards::Resolver.new(dashboard, role: "owner").call["views"][0]["sections"][0]["widgets"][0]
    end

    it "mídia mostra o que toca e só os controles que o ponto aceita" do
      p = media(address: { "supports" => %w[pause resume volume] })
      w = resolve("id" => "w1", "type" => "media", "bind" => p.id)
      expect(w["data"]).to include("media" => { "state" => "playing", "title" => "Jornal", "volume" => 20 }, "controls" => %w[resume pause volume])
    end

    it "a Echo (speaker) usa o mesmo widget sem caso especial: só o volume" do
      echo = create(:point, device: device, site: site, name: "Echo", capability: "speaker", value: "online")
      w = resolve("id" => "w2", "type" => "media", "bind" => echo.id)
      expect(w["data"]["controls"]).to eq(%w[volume])
      expect(w["data"]["media"]).to eq("state" => "online")
    end

    it "o painel automático escolhe o widget pela capacidade (plugin falso)" do
      fake = Class.new(Dashboards::Widgets::Base) { describe type: "fake_media", label: "Falso", bind: true, auto: %w[media] }
      stub_const("Dashboards::Widgets::FakeMediaWidget", fake)
      stub_const("Dashboards::Widgets::PLUGINS", %w[FakeMediaWidget MediaWidget RemoteWidget])
      p = media
      expect(Dashboards::Widgets.for_capability("media")).to eq(fake)
      views = Dashboards::Generator.new(site).call["views"]
      types = views.flat_map { |v| v["sections"] }.flat_map { |s| s["widgets"] }.map { |w| [ w["type"], w["bind"] ] }
      expect(types).to include([ "fake_media", p.id ])
    end

    it "controle remoto lista os botões aprendidos" do
      r = create(:point, device: device, site: site, name: "Controle", capability: "remote", address: { "codes" => { "Ligar" => "x", "Volume +" => "y" } })
      w = resolve("id" => "w3", "type" => "remote", "bind" => r.id)
      expect(w["data"]).to include("buttons" => [ "Ligar", "Volume +" ], "learn" => true)
    end
  end

  describe Proto do
    it "codifica e decodifica varint, texto, bool, float e fixed32" do
      bytes = Proto.encode([ [ 1, :varint, 300 ], [ 2, :string, "olá" ], [ 3, :bool, true ], [ 4, :float, 1.5 ], [ 5, :fixed32, 0xDEADBEEF ], [ 6, :varint, nil ] ])
      f = Proto.decode(bytes)
      expect(f[1]).to eq([ 300 ])
      expect(Proto.string(f[2].first)).to eq("olá")
      expect(f[3]).to eq([ 1 ])
      expect(Proto.float(f[4].first)).to eq(1.5)
      expect(Proto.fixed32(f[5].first)).to eq(0xDEADBEEF)
      expect(f.key?(6)).to be(false)
      expect(Proto.read_varint(Proto.varint(-1), 0).first).to eq(0xFFFF_FFFF_FFFF_FFFF)
    end
  end

  describe Mdns do
    def answer(type, inst, host, port, ip, txt)
      m = Resolv::DNS::Message.new(0)
      m.qr = 1
      m.add_answer(type, 120, Resolv::DNS::Resource::IN::PTR.new(Resolv::DNS::Name.create(inst)))
      m.add_additional(inst, 120, Resolv::DNS::Resource::IN::SRV.new(0, 0, port, Resolv::DNS::Name.create(host)))
      m.add_additional(inst, 120, Resolv::DNS::Resource::IN::TXT.new(*txt)) if txt.any?
      m.add_additional(host, 120, Resolv::DNS::Resource::IN::A.new(ip))
      m.encode
    end

    it "pergunta PTR com resposta unicast e junta PTR, SRV, TXT e A de cada aparelho" do
      q = Resolv::DNS::Message.decode(Mdns.query("_esphomelib._tcp.local"))
      expect(q.question.first.first.to_s).to eq("_esphomelib._tcp.local")
      type = "_esphomelib._tcp.local"
      packets = [
        [ answer(type, "sala.#{type}", "sala.local", 6053, "192.168.0.10", [ "friendly_name=Sensor da sala", "board=esp32", "flag" ]), "192.168.0.10" ],
        [ answer(type, "sala.#{type}", "sala.local", 6053, "192.168.0.10", []), "192.168.0.10" ],
        [ "lixo", "192.168.0.99" ]
      ]
      list = Mdns.parse_all(type, packets)
      expect(list).to eq([ { "name" => "sala", "host" => "192.168.0.10", "port" => 6053, "txt" => { "friendly_name" => "Sensor da sala", "board" => "esp32", "flag" => "" } } ])
    end

    it "varre só uma rede pequena" do
      expect(Mdns.targets("192.168.0.0/30")).to eq(%w[192.168.0.1 192.168.0.2 192.168.0.3])
      expect(Mdns.targets("10.0.0.0/8")).to eq([])
    end
  end

  describe "aparelho da rede (LanPlugin) com plugin falso" do
    let(:plugin) do
      Class.new(Integrations::LanPlugin) do
        describe key: "fake_lan", title: "Falso", icon: "chip", description: "Aparelho falso", driver: "fake_tv"
        port 1234
        secrets :key
        mdns "_fake._tcp"
        def self.probe(i)
          raise Integrations::Error, "sem resposta" if i.settings["host"] == "0.0.0.0"

          { "id" => "fake-1", "kind" => "fake_tv", "name" => "Falso", "address" => { "host" => i.settings["host"] },
            "points" => [ { "name" => "TV", "capability" => "media" } ] }
        end
      end
    end

    before do
      stub_const("Integrations::FakeLanPlugin", plugin)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[FakeLanPlugin])
    end

    it "guarda endereço e segredo cifrado, lê e adota sem cadastrar nada sozinho" do
      expect(Integrations::FakeLanPlugin.setup(site, ActionController::Parameters.new(host: "")).alert).to match(/IP/)
      o = Integrations::FakeLanPlugin.setup(site, ActionController::Parameters.new(host: "192.168.0.7", key: "segredo"))
      i = o.integration
      expect(o.to).to eq(:found)
      expect(i.settings).to include("host" => "192.168.0.7", "port" => 1234)
      expect(i.secrets).to eq("key" => "segredo")
      expect(Integration.connection.select_value("SELECT credentials FROM integrations WHERE id = '#{i.id}'")).not_to include("segredo")
      expect(site.devices.where(driver: "fake_tv")).to be_empty
      Integrations.adopt!(i, { "fake-1" => "" })
      expect(site.devices.find_by!(driver: "fake_tv").points.first.capability).to eq("media")
    end

    it "erro de leitura vira aviso, não exceção" do
      o = Integrations::FakeLanPlugin.setup(site, ActionController::Parameters.new(host: "0.0.0.0"))
      expect(o.alert).to match(/sem resposta/)
    end

    it "procurar na rede só lista (mDNS do plugin)" do
      allow(Mdns).to receive(:browse).with("_fake._tcp").and_return([ { "name" => "tv", "host" => "192.168.0.8", "port" => 1234, "txt" => {} } ])
      expect(Integrations::FakeLanPlugin.discover.first["host"]).to eq("192.168.0.8")
      expect(Integration.count).to eq(0)
    end
  end
end
