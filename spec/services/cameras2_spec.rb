require "rails_helper"

# cameras2: perfil de reprodução por fabricante (dado), lista de gravações do DVR
# (Dahua/Intelbras e Hikvision, sempre com servidor falso), linha do tempo, limite de
# vídeos por pessoa, token do HLS, proxy do WebSocket e a reprodução no go2rtc.
RSpec.describe "Câmeras: DVR, reprodução e ao vivo pelo Rails" do
  let(:tenant) { create(:tenant) }
  let(:site) { within(tenant) { create(:site, name: "Casa", timezone: "America/Sao_Paulo") } }
  let(:dvr) do
    within(tenant) do
      d = create(:device, site: site, driver: "go2rtc", name: "DVR Intelbras MHDX 3216",
                          address: { "host" => "192.168.68.115", "port" => 554, "username" => "admin" })
      d.update!(credential: "s3nha")
      d
    end
  end
  let(:cam) { within(tenant) { create(:point, device: dvr, name: "Garagem", capability: "stream", address: { "path" => "/cam/realmonitor?channel=17&subtype=1" }) } }
  let(:zone) { ActiveSupport::TimeZone["America/Sao_Paulo"] }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  around do |ex|
    old = ENV.fetch("GO2RTC_URL", nil)
    ENV["GO2RTC_URL"] = "http://go2rtc:1984"
    within(tenant) { ex.run }
  ensure
    ENV["GO2RTC_URL"] = old
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  describe Cameras::Playback do
    it "escolhe o perfil pelo caminho, pelo fabricante ou pelo aparelho, sem código por marca" do
      expect(described_class.profile(cam).first).to eq("dahua")
      expect(described_class.channel(cam)).to eq(17)
      hik = create(:point, device: dvr, name: "Hik", capability: "stream", address: { "path" => "/Streaming/Channels/1702" })
      expect(described_class.profile(hik).first).to eq("hikvision")
      expect(described_class.channel(hik)).to eq(17)
      other = create(:point, device: dvr, name: "Outra", capability: "stream", address: { "path" => "/live" })
      expect(described_class.available?(other)).to be(false)
      dvr.update!(manufacturer: "Intelbras")
      expect(described_class.profile(other).first).to eq("dahua")
      dvr.update!(address: dvr.address.merge("playback" => "off"))
      expect(described_class.available?(cam.reload)).to be(false)
      dvr.update!(address: dvr.address.merge("playback" => "hikvision"))
      expect(described_class.profile(cam.reload).first).to eq("hikvision")
    end

    it "monta a fonte RTSP da reprodução no fuso do local, com a senha só aqui" do
      from = zone.local(2026, 11, 12, 14, 3, 10)
      src = described_class.source(cam, from)
      expect(src).to eq("rtsp://admin:s3nha@192.168.68.115:554/cam/playback?channel=17&starttime=2026_11_12_14_03_10&endtime=2026_11_12_16_03_10#backchannel=0")
      hik = create(:point, device: dvr, name: "Hik", capability: "stream", address: { "path" => "/Streaming/Channels/102" })
      expect(described_class.source(hik, from)).to include("/Streaming/tracks/101?starttime=20261112T140310Z&endtime=20261112T160310Z")
      cloud = create(:point, device: dvr, name: "Nuvem", capability: "stream", address: { "path" => "/x", "on_demand" => true })
      expect { described_class.source(cloud, from) }.to raise_error(Cameras::Error)
    end
  end

  describe "linha do tempo do DVR Dahua/Intelbras (mediaFileFind.cgi, Digest)" do
    let(:base) { "http://192.168.68.115/cgi-bin/mediaFileFind.cgi" }
    let(:challenge) { { status: 401, headers: { "WWW-Authenticate" => 'Digest realm="Login to DVR", qop="auth", nonce="abc123", opaque="x"' } } }
    let(:found) do
      <<~TXT
        found=3
        items[0].Channel=16
        items[0].StartTime=2026-11-12 00:00:00
        items[0].EndTime=2026-11-12 01:00:00
        items[0].Flags[0]=Timing
        items[0].Type=dav
        items[1].Channel=16
        items[1].StartTime=2026-11-12 01:00:01
        items[1].EndTime=2026-11-12 02:00:00
        items[1].Type=dav
        items[2].Channel=16
        items[2].StartTime=2026-11-12 14:03:00
        items[2].EndTime=2026-11-12 14:04:30
        items[2].Events[0]=VideoMotion
        items[2].Flags[0]=Event
      TXT
    end

    def stub_dvr(find_status: 200)
      stub_request(:get, "#{base}?action=factory.create").to_return(challenge, { body: "result=08137\r\n" })
      find = stub_request(:get, base).with(query: hash_including("action" => "findFile", "object" => "08137", "condition.Channel" => "17",
                                                                 "condition.StartTime" => "2026-11-12 00:00:00", "condition.EndTime" => "2026-11-12 23:59:59"))
             .to_return(challenge, { status: find_status, body: find_status == 200 ? "OK" : "Error" })
      stub_request(:get, "#{base}?action=findNextFile&object=08137&count=100").to_return(challenge, { body: found })
      %w[close destroy].each { |a| stub_request(:get, "#{base}?action=#{a}&object=08137").to_return(challenge, { body: "OK" }) }
      find
    end

    it "junta os trechos gravados, separa o movimento e responde com digest" do
      stub_dvr
      t = Cameras::Timeline.for(cam, "2026-11-12")
      expect(t["available"]).to be(true)
      expect(t["error"]).to be_nil
      expect(t["recordings"].size).to eq(2) # 00:00–02:00 (emendados) e 14:03
      expect(Time.iso8601(t["recordings"][0]["to"])).to eq(zone.local(2026, 11, 12, 2))
      expect(t["events"]).to eq([ { "from" => zone.local(2026, 11, 12, 14, 3).iso8601, "to" => zone.local(2026, 11, 12, 14, 4, 30).iso8601, "kind" => "motion", "label" => "Movimento" } ])
      expect(WebMock).to have_requested(:get, "#{base}?action=findNextFile&object=08137&count=100")
        .with { |req| req.headers["Authorization"].to_s.start_with?("Digest ") && req.headers["Authorization"].include?('username="admin"') }
      expect(WebMock).to have_requested(:get, "#{base}?action=destroy&object=08137").twice # desafio + com senha
      # Segunda vez: cache (o DVR não é chamado de novo).
      Cameras::Timeline.for(cam, "2026-11-12")
      expect(WebMock).to have_requested(:get, "#{base}?action=factory.create").twice
    end

    it "dia sem gravação, senha errada e DVR fora viram estado, não exceção" do
      stub_dvr(find_status: 400)
      expect(Cameras::Timeline.for(cam, "2026-11-12")["recordings"]).to eq([])
      cache.clear
      stub_request(:get, "#{base}?action=factory.create").to_return(challenge, challenge)
      expect(Cameras::Timeline.for(cam, "2026-11-12")["error"]).to include("usuário ou a senha")
      cache.clear
      stub_request(:get, "#{base}?action=factory.create").to_raise(Errno::EHOSTUNREACH)
      expect(Cameras::Timeline.for(cam, "2026-11-12")["error"]).to include("não respondeu")
    end

    it "câmera sem perfil e dia inválido" do
      other = create(:point, device: dvr, name: "Outra", capability: "stream", address: { "path" => "/live" })
      t = Cameras::Timeline.for(other, "x")
      expect(t["available"]).to be(false)
      expect(t["day"]).to eq(zone.today.iso8601)
      expect(Cameras::Timeline.parse_day((zone.today + 3).iso8601, zone)).to eq(zone.today)
    end
  end

  describe "linha do tempo Hikvision (ISAPI, páginas)" do
    it "pede a trilha do canal e segue enquanto vier MORE" do
      dvr.update!(address: dvr.address.merge("playback" => "hikvision", "http_port" => 8080))
      hik = create(:point, device: dvr, name: "Hik", capability: "stream", address: { "path" => "/Streaming/Channels/302" })
      page = lambda do |status, items|
        matches = items.map do |a, b, kind|
          "<searchMatchItem><timeSpan><startTime>2026-11-12T#{a}Z</startTime><endTime>2026-11-12T#{b}Z</endTime></timeSpan>" \
            "<metadataMatches><metadataDescriptor>recordType.meta.hikvision.com/#{kind}</metadataDescriptor></metadataMatches></searchMatchItem>"
        end.join
        { body: %(<CMSearchResult xmlns="http://www.hikvision.com/ver20/XMLSchema"><responseStatusStrg>#{status}</responseStatusStrg><matchList>#{matches}</matchList></CMSearchResult>) }
      end
      stub = stub_request(:post, "http://192.168.68.115:8080/ISAPI/ContentMgmt/search")
             .to_return(page.call("MORE", [ %w[08:00:00 09:00:00 timing] ]), page.call("OK", [ %w[08:10:00 08:11:00 MOTION] ]))
      t = Cameras::Timeline.for(hik, "2026-11-12")
      expect(t["recordings"].size).to eq(1)
      expect(t["events"].first["kind"]).to eq("motion")
      expect(stub).to have_been_requested.twice
      expect(WebMock).to have_requested(:post, "http://192.168.68.115:8080/ISAPI/ContentMgmt/search").with(body: /<trackID>301<\/trackID>/).twice
    end
  end

  describe Cameras::Streams do
    it "segura o limite por pessoa e libera a vaga" do
      ENV["CAMERA_STREAMS_PER_USER"] = "2"
      expect(described_class.acquire("u1", "a")).to be(true)
      expect(described_class.acquire("u1", "b")).to be(true)
      expect(described_class.acquire("u1", "c")).to be(false)
      expect(described_class.acquire("u1", "a")).to be(true) # renovar a mesma passa
      expect(described_class.acquire("u2", "c")).to be(true)
      described_class.release("u1", "a")
      expect(described_class.acquire("u1", "c")).to be(true)
      described_class.touch("u1", "d")
      expect(described_class.count("u1")).to eq(3)
      travel(Cameras::Streams::TTL + 1) { expect(described_class.count("u1")).to eq(0) }
    ensure
      ENV.delete("CAMERA_STREAMS_PER_USER")
    end
  end

  it "token do HLS: ida e volta, adulterado não passa" do
    user = create(:user, tenant: tenant)
    t = Cameras::HlsToken.generate(cam, user, cam.id)
    expect(t).to match(/\A[A-Za-z0-9_=-]+\z/)
    expect(Cameras::HlsToken.verify(t)).to eq("p" => cam.id, "u" => user.id, "s" => cam.id)
    expect(Cameras::HlsToken.verify("#{t}x")).to be_nil
  end

  describe Drivers::Go2rtc do
    let(:user) { create(:user, tenant: tenant) }

    it "reprodução: põe a fonte no go2rtc com dono, troca a anterior e o sync tira as órfãs" do
      put = stub_request(:put, %r{go2rtc:1984/api/streams\?name=pb_\h{16}&src=rtsp}).to_return(status: 400)
      del = stub_request(:delete, %r{go2rtc:1984/api/streams\?src=pb_}).to_return(status: 400)
      name = described_class.playback!(cam, zone.local(2026, 11, 12, 14), user: user)
      expect(name).to match(described_class::PLAYBACK)
      expect(put).to have_been_requested
      expect(described_class.playback_owner(name)).to eq("point" => cam.id, "user" => user.id)
      other = create(:user, tenant: tenant)
      described_class.stop_playback!(name, user: other) # de outra pessoa: nada
      expect(del).not_to have_been_requested
      name2 = described_class.playback!(cam, zone.local(2026, 11, 12, 14, 0, 30), user: user, replace: name)
      expect(del).to have_been_requested.once
      expect(described_class.playback_owner(name)).to be_nil

      stub_request(:get, "http://go2rtc:1984/api/streams").to_return(body: { "pb_00000000000000aa" => {}, name2 => {} }.to_json)
      stub_request(:put, %r{go2rtc:1984/api/streams\?name=}).to_return(status: 400)
      described_class.sync!
      expect(WebMock).to have_requested(:delete, "http://go2rtc:1984/api/streams?src=pb_00000000000000aa")
      expect(WebMock).not_to have_requested(:delete, "http://go2rtc:1984/api/streams?src=#{name2}")
    end

    it "HLS: índice principal com a sessão e os arquivos permitidos" do
      stub_request(:get, "http://go2rtc:1984/api/stream.m3u8?src=#{cam.id}&mp4=")
        .to_return(body: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=192000\nhls/playlist.m3u8?id=AbC123xy\n")
      body, sid = described_class.hls_master(cam.id)
      expect(sid).to eq("AbC123xy")
      expect(body).to include("hls/playlist.m3u8")
      stub_request(:get, "http://go2rtc:1984/api/hls/segment.m4s?id=AbC123xy&n=3").to_return(body: "SEG")
      expect(described_class.hls_file("segment.m4s", "AbC123xy", "3")).to eq("SEG")
      expect { described_class.hls_file("../api/streams", "x") }.to raise_error(described_class::Error)
      expect(described_class.ws_target("pb_1")).to eq("http://go2rtc:1984/api/ws?src=pb_1")
    end

    it "WebRTC da reprodução não mexe na espera de falha da câmera" do
      stub_request(:post, "http://go2rtc:1984/api/webrtc?src=pb_00000000000000bb").to_return(status: 500)
      expect { described_class.webrtc(cam, "v=0", src: "pb_00000000000000bb") }.to raise_error(described_class::Error)
      expect(described_class.failures(cam)).to eq(0)
    end
  end

  describe Cameras::WsProxy do
    it "repassa o aperto de mão e copia os bytes nos dois sentidos" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      got = Queue.new
      fake = Thread.new do
        s = server.accept
        head = +""
        head << s.readpartial(1024) until head.include?("\r\n\r\n")
        got << head
        s.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: xyz\r\n\r\n")
        got << s.readpartial(1024)
        s.write("VIDEO")
        sleep 0.2
        s.close
      end
      client, browser = UNIXSocket.pair
      closed = Queue.new
      thread = described_class.start(client, "http://127.0.0.1:#{port}/api/ws?src=abc", "dGhlIHNhbXBsZSBub25jZQ==", on_close: -> { closed << true })
      reply = +""
      reply << browser.readpartial(1024) until reply.include?("\r\n\r\n")
      expect(reply).to start_with("HTTP/1.1 101")
      head = got.pop
      expect(head).to include("GET /api/ws?src=abc HTTP/1.1", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==")
      expect(head).not_to include("Origin")
      browser.write("{\"type\":\"mse\"}")
      expect(got.pop).to eq("{\"type\":\"mse\"}")
      data = reply.split("\r\n\r\n", 2)[1].to_s
      data << browser.readpartial(1024) until data.include?("VIDEO")
      expect(data).to eq("VIDEO")
      thread.join(3)
      expect(closed.pop(timeout: 3)).to be(true)
      fake.join(1)
    ensure
      server&.close
    end

    it "go2rtc que não aceita o WebSocket: 502 para o navegador" do
      server = TCPServer.new("127.0.0.1", 0)
      fake = Thread.new do
        s = server.accept
        s.readpartial(1024)
        s.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        s.close
      end
      client, browser = UNIXSocket.pair
      described_class.start(client, "http://127.0.0.1:#{server.addr[1]}/api/ws?src=x", "dGhlIHNhbXBsZSBub25jZQ==").join(3)
      expect(browser.read).to start_with("HTTP/1.1 502")
      fake.join(1)
    ensure
      server&.close
    end
  end
end
