require "rails_helper"

# resto (paridade, 2026-11-03): telas e API do que faltava. Nada de rede real.
RSpec.describe "Paridade: resto (telas e API)" do
  let(:user) { create(:user) }
  let!(:site) { within(user.tenant) { create(:site, name: "Casa") } }
  let(:memory) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(memory)
    post("/entrar", params: { email: user.email, password: "12345678" })
  end

  describe "log de depuração por integração (7.7)" do
    it "liga no menu, junta varredura e comando (saneado) e desligar baixa o log" do
      fake = Class.new(Integrations::SchemaPlugin) do
        describe key: "teste_debug", title: "Teste Debug", icon: "chip", description: "Teste"
        texts en: { title: "Debug test", description: "Test" }, es: { title: "Prueba debug", description: "Prueba" }
        def self.entries(_i) = [ entry(id: "d:1", name: "Teste Aparelho", points: [ point("on", "onoff", name: "Teste Liga") ]) ]
        def self.read(_device) = { "on" => true }
        def self.write(point, _value) = debug(point.device.integration, "mandei para 192.168.0.77 com token=abc123")
      end
      stub_const("Integrations::TesteDebugPlugin", fake)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[TesteDebugPlugin])
      i = within(user.tenant) { site.integrations.create!(driver: "teste_debug", name: "Teste Debug") }

      get "/locais/#{site.id}/integracoes"
      expect(response.body).to include("Ligar log de depuração")
      post "/integracoes/#{i.id}/depuracao"
      expect(flash[:notice]).to include("log de depuração ligado")
      get "/locais/#{site.id}/integracoes"
      expect(response.body).to include("Log de depuração ligado", "Desligar e baixar o log")

      within(user.tenant) do
        Integrations.sync!(i.reload)
        Integrations.adopt!(i, "d:1" => "")
        p = i.devices.first.points.first
        ExecuteCommandJob.perform_now(Points::Command.call(p, "off", source: "web").id)
      end
      post "/integracoes/#{i.id}/depuracao"
      expect(response.media_type).to eq("text/plain")
      expect(response.body).to include("debug ligado", "varredura: 1 aparelho(s): d:1", "comando Teste Liga: off", "mandei para")
      expect(response.body).not_to include("192.168.0.77", "abc123")
      expect(Integrations::DebugLog.on?(i.reload)).to be false
    end
  end

  describe "DHCP passivo (7.23)" do
    def dhcp(mac:, host:, ip:)
      pkt = [ 1, 1, 6, 0 ].pack("C4") + "\0".b * 24 + [ mac.delete(":") ].pack("H*") + "\0".b * 202 + DhcpPacket::COOKIE
      opt = ->(c, v) { [ c, v.bytesize ].pack("CC") + v.b }
      pkt + opt.call(53, [ 3 ].pack("C")) + opt.call(12, host) + opt.call(50, ip.split(".").map(&:to_i).pack("C4")) + opt.call(60, "udhcp 1.0") + [ 255 ].pack("C")
    end

    it "o pacote do aparelho vira MAC, nome e IP; a chave grava e a descoberta do plugin acha" do
      lease = DhcpPacket.parse(dhcp(mac: "a4:cf:12:00:00:01", host: "shellyplug-s-0001", ip: "192.168.0.31"))
      expect(lease).to eq("mac" => "A4:CF:12:00:00:01", "hostname" => "shellyplug-s-0001", "ip" => "192.168.0.31", "vendor" => "udhcp 1.0", "type" => "request")
      expect(DhcpPacket.parse("lixo")).to be_nil

      _, key = within(user.tenant) { ServiceApiKey.issue(user, name: "Teste DHCP", scopes: %w[write], site_ids: [ site.id ]) }
      post "/api/v1/dhcp/leases", params: { leases: [ lease, { mac: "nada" } ] }.to_json, headers: { "X-Api-Key" => key, "Content-Type" => "application/json" }
      expect(response.parsed_body.dig("data", "stored")).to eq(1), response.body
      within(user.tenant) do
        found = Host.dhcp([ { hostname: "shelly*" } ])
        expect(found).to contain_exactly(include("host" => "192.168.0.31", "name" => "shellyplug-s-0001"))
      end

      _, read_only = within(user.tenant) { ServiceApiKey.issue(user, name: "Teste leitura", scopes: %w[read], site_ids: [ site.id ]) }
      post "/api/v1/dhcp/leases", params: { leases: [] }.to_json, headers: { "X-Api-Key" => read_only, "Content-Type" => "application/json" }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "descoberta por Bluetooth (7.23)" do
    it "plugin falso com `bluetooth` acha o anúncio que casa pelo nome, fabricante ou serviço" do
      fake = Class.new(Integrations::Plugin) do
        describe key: "teste_ble", title: "Teste BLE", icon: "chip", description: "Teste"
        texts en: { title: "BLE test", description: "Test" }, es: { title: "Prueba BLE", description: "Prueba" }
        bluetooth({ local_name: "Teste*" }, { manufacturer_id: 0x0969 })
      end
      stub_const("Integrations::TesteBlePlugin", fake)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[TesteBlePlugin])
      ble = within(user.tenant) { site.integrations.create!(driver: "bluetooth", name: "Bluetooth") }
      ad = ->(*parts) { parts.map { |t, v| [ v.bytesize + 1, t ].pack("CC") + v.b }.join }
      named = ad.call([ 0x09, "Teste Sensor" ])
      maker = ad.call([ 0xFF, [ 0x0969 ].pack("v") + "xx" ], [ 0x03, [ 0xFD3D ].pack("v") ])
      other = ad.call([ 0x09, "Outro" ])
      within(user.tenant) do
        Ble::Hub.ingest!(ble, [ named, maker, other ].each_with_index.map { |d, n| { "mac" => "AA:BB:CC:DD:EE:0#{n}", "rssi" => -60, "data" => Base64.strict_encode64(d) } })
        expect(fake.discovers?).to be true
        expect(fake.discover.map { |e| e.dig("txt", "mac") }).to contain_exactly("AA:BB:CC:DD:EE:00", "AA:BB:CC:DD:EE:01")
        expect(Integrations::SwitchbotPlugin.discover.map { |e| e["name"] }).to eq([ "AA:BB:CC:DD:EE:01" ])
      end
    end
  end
end
