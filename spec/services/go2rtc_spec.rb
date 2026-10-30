require "rails_helper"

RSpec.describe Drivers::Go2rtc do
  let(:tenant) { create(:tenant) }
  let(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:base) { "http://go2rtc:1984" }
  let(:cams) do
    [ { name: "DVR", host: "192.168.0.10", port: 554, username: "admin", password: "s3nh@:x/y", area: "Sala",
        streams: [ { "name" => "Canal 1", "path" => "/Streaming/Channels/102" }, { "name" => "Canal 2", "path" => "/Streaming/Channels/202" } ] },
      { name: "Sem senha", host: "192.168.0.11", username: "admin", streams: [ { "name" => "Frente", "path" => "/live" } ] },
      { name: "Aberta", host: "192.168.0.12", streams: [ { "name" => "Quintal", "path" => "/V_ENC_001" } ] } ]
  end

  around do |ex|
    old = ENV.fetch("GO2RTC_URL", nil)
    ENV["GO2RTC_URL"] = "http://go2rtc:1984"
    ActsAsTenant.with_tenant(tenant) { ex.run }
  ensure
    ENV["GO2RTC_URL"] = old
    FileUtils.rm_rf(described_class::SNAPSHOT_DIR)
  end

  def import(list) = within(tenant) { described_class.import!(site, list.map(&:stringify_keys)) }


  def stream(name) = within(tenant) { Point.find_by!(name: name) }

  it "importa câmeras (idempotente, senha cifrada) e monta a fonte RTSP" do
    within(tenant) { create(:area, site: site, name: "Sala") }
    expect(import(cams)).to eq(devices: 3, points: 4)
    expect(import(cams.map { |c| c.merge(password: nil) })).to eq(devices: 0, points: 0)
    dvr = within(tenant) { Device.find_by!(name: "DVR") }
    expect(dvr.area.name).to eq("Sala")
    expect(dvr.credential).to eq("s3nh@:x/y") # senha vazia na reimportação manteve a gravada
    expect(dvr.read_attribute_before_type_cast(:credential)).not_to include("s3nh")
    expect(stream("Canal 1")).to have_attributes(capability: "stream", writable: false, history: "none")
    expect(described_class.source(stream("Canal 1"))).to eq("rtsp://admin:s3nh%40%3Ax%2Fy@192.168.0.10:554/Streaming/Channels/102")
    expect(described_class.source(stream("Quintal"))).to eq("rtsp://192.168.0.12:554/V_ENC_001")
    expect(described_class.source(stream("Frente"))).to be_nil # usuário sem senha: fica de fora
  end

  it "sync! põe no go2rtc os streams que faltam e tira os que sobraram" do
    import(cams)
    c1, c2, quintal = stream("Canal 1"), stream("Canal 2"), stream("Quintal")
    old = "11111111-2222-3333-4444-555555555555"
    stub_request(:get, "#{base}/api/streams").to_return(body: {
      c1.id => { "producers" => [ { "url" => described_class.source(c1) } ] },
      c2.id => { "producers" => [ { "url" => "rtsp://antigo" } ] },
      old => { "producers" => [] }, "manual" => {}
    }.to_json)
    put = stub_request(:put, %r{#{base}/api/streams\?}).to_return(status: 400, body: "Config file disabled")
    del = stub_request(:delete, "#{base}/api/streams?src=#{old}").to_return(status: 200)

    expect(described_class.sync!).to eq(3)
    expect(put).to have_been_requested.twice
    expect(a_request(:put, "#{base}/api/streams").with(query: { name: quintal.id, src: described_class.source(quintal) })).to have_been_made
    expect(a_request(:put, "#{base}/api/streams").with(query: hash_including(name: c1.id))).not_to have_been_made
    expect(del).to have_been_requested
  end

  # No Dell: o DELETE sem arquivo de config também responde 400 e derrubava o
  # sync a cada minuto, um stream removido por vez.
  it "sync!: 400 do DELETE é normal e um stream ruim não derruba os outros" do
    import(cams)
    c1, c2, quintal = stream("Canal 1"), stream("Canal 2"), stream("Quintal")
    olds = %w[11111111-2222-3333-4444-555555555555 66666666-2222-3333-4444-555555555555]
    stub_request(:get, "#{base}/api/streams").to_return(body: olds.index_with({}).to_json)
    stub_request(:put, %r{#{base}/api/streams\?}).to_return(status: 400, body: "config file disabled")
    stub_request(:put, %r{#{base}/api/streams\?name=#{c1.id}}).to_return(status: 500)
    stub_request(:delete, "#{base}/api/streams?src=#{olds[0]}").to_raise(Errno::ECONNRESET)
    del = stub_request(:delete, "#{base}/api/streams?src=#{olds[1]}").to_return(status: 400, body: "config file disabled")

    expect(described_class.sync!).to eq(3)
    expect(a_request(:put, "#{base}/api/streams").with(query: hash_including(name: c2.id))).to have_been_made
    expect(a_request(:put, "#{base}/api/streams").with(query: hash_including(name: quintal.id))).to have_been_made
    expect(del).to have_been_requested
    expect(stream("Canal 1").quality).to eq("unavailable")
    expect(stream("Quintal").quality).not_to eq("unavailable")
  end

  it "sem GO2RTC_URL (VPS) não faz nada" do
    ENV["GO2RTC_URL"] = nil
    expect(described_class.sync!).to be_nil
    import(cams)
    expect { described_class.snapshot(stream("Quintal")) }.to raise_error(described_class::Error, /sem conexão/)
    expect(stream("Quintal").quality).to eq("unavailable")
  end

  it "snapshot: guarda só o último quadro e reaproveita por alguns segundos" do
    import(cams)
    p = stream("Quintal")
    req = stub_request(:get, "#{base}/api/frame.jpeg?src=#{p.id}").to_return(body: "JPEG1")
    expect(described_class.snapshot(p)).to eq("JPEG1")
    expect(described_class.snapshot(p)).to eq("JPEG1")
    expect(req).to have_been_requested.once
    expect(Reading.where(point_id: p.id)).to be_empty
  end

  it "go2rtc fora do ar ou câmera falhando: erro e ponto indisponível; volta a good no próximo quadro" do
    import(cams)
    p = stream("Quintal")
    stub_request(:get, "#{base}/api/frame.jpeg?src=#{p.id}").to_raise(Errno::ECONNREFUSED).then.to_return(status: 500).then.to_return(body: "OK")
    expect { described_class.snapshot(p) }.to raise_error(described_class::Error, /fora do ar/)
    expect { described_class.snapshot(p) }.to raise_error(described_class::Error, /500/)
    expect(p.reload.quality).to eq("unavailable")
    described_class.snapshot(p)
    expect(p.reload.quality).to eq("good")
  end

  it "webrtc repassa a oferta e devolve a resposta" do
    import(cams)
    p = stream("Quintal")
    stub_request(:post, "#{base}/api/webrtc?src=#{p.id}").with(body: "v=0 oferta").to_return(body: "v=0 resposta")
    expect(described_class.webrtc(p, "v=0 oferta")).to eq("v=0 resposta")
    expect { described_class.webrtc(stream("Frente"), "v=0") }.to raise_error(described_class::Error)
  end

  it "o job de sincronização e o painel automático usam as câmeras" do
    import(cams)
    stub_request(:get, "#{base}/api/streams").to_return(body: "{}")
    stub_request(:put, %r{#{base}/api/streams}).to_return(status: 200)
    expect(Go2rtcSyncJob.perform_now).to eq(3)
    defn = within(tenant) { Dashboards::Generator.call(site) }
    home = defn["views"].first
    cams_section = home["sections"].find { |s| s["id"] == "s-home-cameras" }
    expect(cams_section["widgets"].map { |w| w["type"] }.uniq).to eq([ "camera" ])
    expect(Dashboards::Schema.errors(defn)).to be_empty
  end
end
