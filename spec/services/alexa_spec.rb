require "rails_helper"

RSpec.describe "Alexa (anúncio não oficial)" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:base) { "https://alexa.amazon.com.br" }
  let(:cookies_file) do
    { "format" => "alexapy.cookies", "version" => 1, "cookies" => [
      { "name" => "session-id", "value" => "S1", "domain" => "amazon.com.br" },
      { "name" => "csrf", "value" => "C1", "domain" => "amazon.com.br" },
      { "name" => "csrf", "value" => "OUTRO", "domain" => "amazon.com" },
      { "name" => "ft-session", "value" => "X", "domain" => "parents.amazon.com.br" }
    ] }.to_json
  end
  let(:devices) do
    { "devices" => [
      { "accountName" => "Echo Cozinha", "deviceFamily" => "ECHO", "deviceType" => "A3EH", "serialNumber" => "G0C", "online" => true, "deviceOwnerCustomerId" => "CUST" },
      { "accountName" => "Echo Escritório", "deviceFamily" => "ECHO", "deviceType" => "A4ZX", "serialNumber" => "G0E", "online" => false, "deviceOwnerCustomerId" => "CUST" },
      { "accountName" => "Todo lugar", "deviceFamily" => "WHA", "deviceType" => "A3C9", "serialNumber" => "W1", "online" => true },
      { "accountName" => "FireTV", "deviceFamily" => "FIRE_TV", "deviceType" => "A265", "serialNumber" => "F1", "online" => true }
    ] }
  end

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def stub_devices = stub_request(:get, "#{base}/api/devices-v2/device?cached=true").with(headers: { "Cookie" => "session-id=S1; csrf=C1" }).to_return(body: devices.to_json)
  def stub_preview = stub_request(:post, "#{base}/api/behaviors/preview").with(headers: { "csrf" => "C1" }).to_return(body: "")
  def import = Alexa::Import.call(site, cookies_file)
  def echo(name) = Device.find_by!(name: name).points.first

  it "lê os cookies do arquivo do alexa_media (só os do domínio .com.br)" do
    expect(Alexa::Import.cookies_from(cookies_file)).to eq("session-id" => "S1", "csrf" => "C1")
    expect(Alexa::Import.cookies_from("a" => 1)).to eq("a" => "1")
  end

  it "importa as Echo (que falam), a Fire TV e o grupo só com a mídia, guarda cookies cifrados e é idempotente" do
    stub_devices
    expect(import).to eq(devices: 4, points: 2, echos: 2)
    expect(Device.find_by!(name: "FireTV").points.pluck(:capability)).not_to include("speaker") # aviso só nas Echo
    integration = site.integrations.sole
    expect(integration.status).to eq("ok")
    expect(integration.secrets).to eq("cookies" => { "session-id" => "S1", "csrf" => "C1" })
    expect(Integration.connection.select_value("select credentials from integrations")).not_to include("session-id")
    cozinha = Device.find_by!(name: "Echo Cozinha")
    expect(cozinha).to have_attributes(driver: "alexa", external_id: "G0C", integration: integration, status: "online")
    expect(cozinha.address).to eq("device_type" => "A3EH", "customer_id" => "CUST")
    expect(echo("Echo Cozinha")).to have_attributes(capability: "speaker", value: "online")
    expect(echo("Echo Escritório").value).to eq("offline")
    expect(import).to eq(devices: 0, points: 0, echos: 2)
  end

  it "sessão recusada vira erro na integração" do
    stub_request(:get, "#{base}/api/devices-v2/device?cached=true").to_return(status: 401)
    expect { import }.to raise_error(Alexa::Client::Error, /expirada/)
    expect(site.integrations.sole).to have_attributes(status: "error", last_error: /expirada/)
  end

  it "monta o anúncio e a fala como sequência com csrf" do
    preview = stub_preview
    client = Alexa::Client.new(cookies: { "csrf" => "C1" })
    target = { serial: "G0C", type: "A3EH", customer_id: "CUST" }
    client.announce([ target ], "  Portão   aberto ", title: "Casa")
    client.speak(target, "Bom dia")
    expect(preview).to have_been_requested.twice
    bodies = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.select { |s| s.uri.path == "/api/behaviors/preview" }.map { |s| JSON.parse(s.body) }
    seq = JSON.parse(bodies.first["sequenceJson"])
    expect(bodies.first).to include("behaviorId" => "PREVIEW", "status" => "ENABLED")
    node = seq["startNode"]
    expect(node["type"]).to eq("AlexaAnnouncement")
    expect(node.dig("operationPayload", "content", 0, "speak")).to eq("type" => "text", "value" => "Portão aberto")
    expect(node.dig("operationPayload", "target", "devices")).to eq([ { "deviceSerialNumber" => "G0C", "deviceTypeId" => "A3EH" } ])
    speak = JSON.parse(bodies.last["sequenceJson"])["startNode"]
    expect(speak["type"]).to eq("Alexa.Speak")
    expect(speak["operationPayload"]).to include("textToSpeak" => "Bom dia", "deviceSerialNumber" => "G0C", "locale" => "pt-BR")
    expect { client.speak(target, " ") }.to raise_error(Alexa::Client::Error, /vazio/)
    client.announce([ target ], %(<speak><prosody volume="soft">Portão aberto.</prosody></speak>))
    last = JSON.parse(WebMock::RequestRegistry.instance.requested_signatures.hash.keys.select { |s| s.uri.path == "/api/behaviors/preview" }.map { |s| JSON.parse(s.body) }.last["sequenceJson"])
    content = last.dig("startNode", "operationPayload", "content", 0)
    expect(content["speak"]).to eq("type" => "ssml", "value" => %(<speak><prosody volume="soft">Portão aberto.</prosody></speak>))
    expect(content.dig("display", "body")).to eq("Portão aberto.")
    expect { Alexa::Client.new(cookies: {}) }.to raise_error(Alexa::Client::Error)
  end

  it "erro de rede e resposta ilegível viram erro do cliente" do
    stub_request(:get, "#{base}/api/devices-v2/device?cached=true").to_raise(SocketError).then.to_return(body: "<html>")
    client = Alexa::Client.new(cookies: { "x" => "1" })
    expect { client.devices }.to raise_error(Alexa::Client::Error, /conexão/)
    expect { client.devices }.to raise_error(Alexa::Client::Error, /ilegível/)
  end

  it "comando announce pela fila fala na Echo e marca a integração" do
    stub_devices
    import
    preview = stub_preview
    command = Points::Command.call(echo("Echo Cozinha"), "announce", "Robô terminou", source: "web")
    perform_enqueued_jobs
    expect(command.reload.status).to eq("confirmed")
    expect(preview).to have_been_requested
    expect { Points::Command.call(echo("Echo Cozinha"), "announce", "x" * 300, source: "web") }.to raise_error(Points::Command::Error, /longo/)
  end

  it "Echo sem integração falha sem sair para a rede" do
    point = create(:point, device: create(:device, site: site, driver: "alexa"), capability: "speaker")
    command = Points::Command.call(point, "speak", "Oi", source: "web")
    perform_enqueued_jobs
    expect(command.reload).to have_attributes(status: "failed", error: /integração/)
  end

  describe Notifier do
    it "canal alexa:<ponto> anuncia título e corpo na Echo, além do aviso no app" do
      stub_devices
      import
      point = echo("Echo Cozinha")
      channels = [ "in_app", "alexa:#{point.id}" ]
      expect(described_class.valid_channels?(channels)).to be true
      expect(described_class.valid_channels?([ "alexa:123" ])).to be false
      expect(described_class.valid_channels?([])).to be false
      expect(described_class.channel_label("alexa:#{point.id}")).to eq("Falar na Echo Cozinha")
      expect(described_class.channel_label("alexa:#{SecureRandom.uuid}")).to eq("Echo removida")
      expect(described_class.channel_choices(site).map(&:first)).to include("push", "alexa:#{point.id}")

      notification = described_class.deliver!(channels, kind: "aviso", title: "Portão aberto", body: "Há 5 min")
      expect(notification).to be_present
      expect(Command.sole).to have_attributes(point_id: point.id, command: "announce", value: "Portão aberto. Há 5 min", source: "automation")
      expect(described_class.deliver!(channels, kind: "aviso", title: "x", dedup_key: "k")).to be_present
      expect(described_class.deliver!(channels, kind: "aviso", title: "x", dedup_key: "k")).to be_nil
      expect(Command.count).to eq(2)
    end

    it "aviso em SSML (vindo do HA): a Echo recebe o SSML, a tela e o push o texto puro" do
      stub_devices
      import
      point = echo("Echo Cozinha")
      ssml = %(<speak><prosody volume="soft">Portão fechado.</prosody></speak>)
      n = described_class.deliver!([ "in_app", "push", "alexa:#{point.id}" ], kind: "aviso", title: "Aviso", body: ssml)
      expect(n.body).to eq("Portão fechado.")
      expect(n.data["ssml"]).to eq(ssml)
      expect(Command.sole).to have_attributes(command: "announce", value: ssml)
    end

    it "regra de aviso aceita Echo como canal" do
      stub_devices
      import
      rule = NotifyRule.new(site: site, point: create(:point, device: create(:device, site: site)), channels: [ "alexa:#{echo('Echo Cozinha').id}" ])
      expect(rule).to be_valid
      rule.channels = [ "fax" ]
      expect(rule).not_to be_valid
    end
  end
end
