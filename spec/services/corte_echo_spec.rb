require "rails_helper"

# G12 (Echo completo): mídia, volume, "não perturbe" e o último Echo chamado
# como pontos, lidos como o alexa_media lê. Tudo por fixture (WebMock): nenhum
# Echo real é comandado e não há login.
RSpec.describe "Corte: Echo completo (G12)" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, name: "Teste Casa") }
  let(:base) { "https://alexa.amazon.com.br" }
  let(:integration) do
    Integration.create!(site: site, driver: "alexa", name: "Teste Alexa", status: "ok", settings: { "host" => "alexa.amazon.com.br" },
                        credentials: { "cookies" => { "session-id" => "S1", "csrf" => "C1" } }.to_json)
  end
  let(:devices) do
    { "devices" => [
      { "accountName" => "Teste Echo Sala", "deviceFamily" => "ECHO", "deviceType" => "A3EH", "serialNumber" => "G0SALA", "online" => true, "deviceOwnerCustomerId" => "CUST" },
      { "accountName" => "Teste Echo Quarto", "deviceFamily" => "KNIGHT", "deviceType" => "A4ZX", "serialNumber" => "G0QUARTO", "online" => false, "deviceOwnerCustomerId" => "CUST" }
    ] }
  end
  let(:volumes) do
    { "volumes" => [ { "dsn" => "G0SALA", "deviceType" => "A3EH", "speakerVolume" => 35, "speakerMuted" => false, "alertVolume" => nil },
                     { "dsn" => "G0QUARTO", "deviceType" => "A4ZX", "speakerVolume" => 10, "speakerMuted" => true } ] }
  end
  let(:dnd) do
    { "doNotDisturbDeviceStatusList" => [ { "deviceSerialNumber" => "G0SALA", "deviceType" => "A3EH", "enabled" => false },
                                         { "deviceSerialNumber" => "G0QUARTO", "deviceType" => "A4ZX", "enabled" => true } ] }
  end
  let(:player) do
    { "playerInfo" => { "state" => "PLAYING", "infoText" => { "title" => "Garota de Ipanema", "subText1" => "Tom Jobim", "subText2" => "Getz/Gilberto" },
                        "provider" => { "providerName" => "Amazon Music" }, "mainArt" => { "url" => "https://m.media-amazon.com/capa.jpg" },
                        "volume" => { "volume" => 35, "muted" => false } } }
  end

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def stub_state!
    stub_request(:get, "#{base}/api/devices-v2/device?cached=true").to_return(body: devices.to_json)
    stub_request(:get, "#{base}/api/devices/deviceType/dsn/audio/v1/allDeviceVolumes").to_return(body: volumes.to_json)
    stub_request(:get, "#{base}/api/dnd/device-status-list").to_return(body: dnd.to_json)
    stub_request(:get, "#{base}/api/np/player?deviceSerialNumber=G0SALA&deviceType=A3EH&screenWidth=2560").to_return(body: player.to_json)
  end

  def point(echo, role) = Device.find_by!(name: echo).points.find_by!("address->>'role' = ?", role)

  it "a varredura lê volume, mídia e 'não perturbe' e cria os pontos genéricos uma vez" do
    stub_state!
    Integrations.sync!(integration)
    media = point("Teste Echo Sala", "media")
    expect(media).to have_attributes(capability: "media", writable: true)
    expect(media.value).to eq("state" => "playing", "title" => "Garota de Ipanema", "artist" => "Tom Jobim", "album" => "Getz/Gilberto",
                              "source" => "Amazon Music", "image" => "https://m.media-amazon.com/capa.jpg", "volume" => 35, "muted" => false)
    expect(Points::Command.commands_for(media)).to match_array(%w[resume pause next previous volume play_media])
    expect(point("Teste Echo Quarto", "media").value).to eq("state" => "idle", "volume" => 10, "muted" => true) # desligada: sem playerInfo
    expect(point("Teste Echo Sala", "dnd").value).to be false
    expect(point("Teste Echo Quarto", "dnd").value).to be true
    expect(point("Teste Echo Sala", "last_called")).to have_attributes(capability: "onoff", writable: false)
    expect(a_request(:get, %r{/api/np/player\?deviceSerialNumber=G0QUARTO})).not_to have_been_made

    expect { Integrations.sync!(integration) }.not_to(change { Point.count })
    expect(Dashboards::Widgets.for_capability("media")).to be_present
  end

  it "comandos de mídia e 'não perturbe' montam as chamadas do alexa_media (fixture, sem Echo real)" do
    stub_state!
    Integrations.sync!(integration)
    pause = stub_request(:post, "#{base}/api/np/command?deviceSerialNumber=G0SALA&deviceType=A3EH")
            .with(headers: { "csrf" => "C1" }, body: { "type" => "PauseCommand" }.to_json).to_return(body: "")
    dnd_put = stub_request(:put, "#{base}/api/dnd/status")
              .with(body: { "deviceSerialNumber" => "G0SALA", "deviceType" => "A3EH", "enabled" => true }.to_json).to_return(body: "{}")
    preview = stub_request(:post, "#{base}/api/behaviors/preview").to_return(body: "")

    Points::Command.call(point("Teste Echo Sala", "media"), "pause", nil, source: "web")
    Points::Command.call(point("Teste Echo Sala", "media"), "play_media", "SPOTIFY: bossa nova", source: "web")
    Points::Command.call(point("Teste Echo Sala", "dnd"), "on", nil, source: "web")
    perform_enqueued_jobs
    expect(Command.pluck(:status).uniq).to eq(%w[confirmed])
    expect([ pause, dnd_put, preview ]).to all(have_been_requested)
    expect(point("Teste Echo Sala", "dnd").value).to be true
    expect { Points::Command.call(point("Teste Echo Sala", "last_called"), "on", nil, source: "web") }.to raise_error(Points::Command::Error)
    expect { Alexa::Client.new(cookies: { "x" => "1" }).player_command({ serial: "S", type: "T" }, "stop") }.to raise_error(Alexa::Client::Error, /desconhecido/)
  end

  it "o último Echo chamado vira ponto quando uma automação escuta esse ponto" do
    stub_state!
    Integrations.sync!(integration)
    flag = point("Teste Echo Quarto", "last_called")
    a = Automation.create!(site: site, name: "Teste Último chamado", kind: "automation", mode: "single")
    a.publish!({ "triggers" => [ { "type" => "state", "point" => flag.id, "to" => true } ], "actions" => [ { "type" => "trace_note", "message" => "chamou" } ] })
    a.update!(enabled: true)
    ts = (Time.current - 20).to_i * 1000
    stub_request(:get, %r{\Ahttps://www\.amazon\.com\.br/alexa-privacy/apd/activity}).to_return(body: '<html><meta name="csrf-token" content="TOK"></html>')
    stub_request(:post, %r{\Ahttps://www\.amazon\.com\.br/alexa-privacy/apd/rvh/customer-history-records-v2/}).to_return(body: {
      "customerHistoryRecords" => [ { "recordKey" => "CUST#A4ZX#X#G0QUARTO", "timestamp" => ts, "utteranceType" => "GENERAL",
                                      "voiceHistoryRecordItems" => [ { "recordItemType" => "CUSTOMER_TRANSCRIPT", "transcriptText" => "boa noite" } ] } ]
    }.to_json)

    expect { Integrations::AlexaPlugin.tick(Time.current) }.to change { a.runs.count }.by(1)
    expect(flag.reload.value).to be true
    expect(point("Teste Echo Sala", "last_called").value).to be false
  end
end
