require "rails_helper"

# cameras2: tela de Câmeras, ao vivo fora de casa (MSE por WebSocket e HLS pelo Rails),
# linha do tempo e reprodução do DVR, na web e na API do app. go2rtc e DVR falsos.
RSpec.describe "Câmeras: tela própria, ao vivo pelo Rails e DVR" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa", timezone: "America/Sao_Paulo") } }
  let!(:dvr) do
    within(tenant) do
      d = create(:device, site: site, driver: "go2rtc", name: "DVR Intelbras", address: { "host" => "192.168.68.115", "username" => "admin" })
      d.update!(credential: "s3nha")
      d
    end
  end
  let!(:garagem) { within(tenant) { create(:point, device: dvr, name: "Garagem", capability: "stream", address: { "path" => "/cam/realmonitor?channel=1&subtype=1" }) } }
  let!(:quintal) { within(tenant) { create(:point, device: dvr, name: "Quintal", capability: "stream", address: { "path" => "/cam/realmonitor?channel=2&subtype=1" }) } }
  let(:go) { "http://go2rtc:1984" }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:ws_headers) { { "Upgrade" => "websocket", "Connection" => "Upgrade", "Sec-WebSocket-Key" => "dGhlIHNhbXBsZSBub25jZQ==", "Sec-WebSocket-Version" => "13" } }

  around do |ex|
    old = ENV.fetch("GO2RTC_URL", nil)
    ENV["GO2RTC_URL"] = go
    ex.run
  ensure
    ENV["GO2RTC_URL"] = old
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  after { travel_back }

  def start_playback(at = "2026-11-12 14:03:10")
    stub_request(:put, %r{#{go}/api/streams\?name=pb_}).to_return(status: 400)
    # Sem bloco: o resto do exemplo fica no mesmo relógio (o dono da reprodução vale PLAYBACK_TTL s no cache).
    travel_to(Time.zone.parse("2026-11-13 12:00"))
    post "/cameras/#{garagem.id}/reproduzir", params: { inicio: at }, as: :json
    JSON.parse(response.body)
  end

  describe "web" do
    before { sign_in }

    it "menu Câmeras, grade com ao vivo automático e câmera com troca rápida" do
      get "/cameras"
      expect(response).to have_http_status(:ok)
      html = response.body
      expect(html).to include(%(href="/cameras"), "Garagem", "Quintal", %(data-controller="camera-nav"))
      expect(html).to include(%(data-camera-autoplay-value="true"), "/cameras/#{garagem.id}/mse", "/cameras/#{garagem.id}/hls")
      get "/cameras/#{garagem.id}"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(data-camera-nav-next-value="/cameras/#{quintal.id}"), %(data-camera-nav-prev-value="/cameras/#{quintal.id}"))
      expect(response.body).to include("camera-timeline", "/cameras/#{garagem.id}/linha-do-tempo", "/cameras/#{garagem.id}/reproduzir", "camera#fullscreen")
      expect(response.body).not_to include("camera#talk") # sem alto-falante
      within(tenant) { garagem.update!(writable: true, address: garagem.address.merge("supports" => %w[record play_media], "talk" => true)) }
      get "/cameras/#{garagem.id}"
      expect(response.body).to include("camera#talk")
    end

    it "local sem câmera: estado vazio e sem menu" do
      other = create(:user)
      within(other.tenant) { create(:site, name: "Loja") }
      sign_in(other)
      get "/cameras"
      expect(response.body).to include("Nenhuma câmera")
      expect(response.body).not_to include(%(href="/cameras"))
    end

    it "linha do tempo no quadro e em JSON" do
      base = "http://192.168.68.115/cgi-bin/mediaFileFind.cgi"
      stub_request(:get, "#{base}?action=factory.create").to_return(body: "result=1\r\n")
      stub_request(:get, base).with(query: hash_including("action" => "findFile")).to_return(body: "OK")
      stub_request(:get, "#{base}?action=findNextFile&object=1&count=100").to_return(body: <<~TXT)
        found=1
        items[0].StartTime=2026-11-12 14:03:00
        items[0].EndTime=2026-11-12 14:05:00
        items[0].Events[0]=VideoMotion
      TXT
      stub_request(:get, /action=(close|destroy)/).to_return(body: "OK")
      travel_to(Time.zone.parse("2026-11-13 12:00")) do
        get "/cameras/#{garagem.id}/linha-do-tempo", params: { dia: "2026-11-12" }
        expect(response.body).to include("camera-timeline", "ss-sb", "Movimento", "camera-playback#playAt")
        get "/cameras/#{garagem.id}/linha-do-tempo.json", params: { dia: "2026-11-12" }
      end
      expect(JSON.parse(response.body)["events"].first["kind"]).to eq("motion")
    end

    it "reproduzir: fonte no go2rtc, WebRTC/MSE só com o dono, parar" do
      data = start_playback
      expect(response).to have_http_status(:ok)
      pb = data["stream"]
      expect(pb).to match(/\Apb_\h{16}\z/)
      expect(data["webrtc"]).to eq("/cameras/#{garagem.id}/ao-vivo?pb=#{pb}")
      expect(data["hls"]).to start_with("/cameras/#{garagem.id}/hls/")
      expect(WebMock).to have_requested(:put, %r{src=rtsp://admin:s3nha@192\.168\.68\.115:554/cam/playback\?channel=1%26starttime=2026_11_12_14_03_10})

      stub_request(:post, "#{go}/api/webrtc?src=#{pb}").to_return(body: "v=0 resposta")
      post "/cameras/#{garagem.id}/ao-vivo?pb=#{pb}", params: "v=0 oferta", headers: { "CONTENT_TYPE" => "application/sdp" }
      expect(response.body).to eq("v=0 resposta")
      # Mesma reprodução por outra câmera: não acha.
      post "/cameras/#{quintal.id}/ao-vivo?pb=#{pb}", params: "v=0 oferta", headers: { "CONTENT_TYPE" => "application/sdp" }
      expect(response).to have_http_status(:not_found)

      stub_request(:delete, "#{go}/api/streams?src=#{pb}").to_return(status: 400)
      delete "/cameras/#{garagem.id}/reproduzir", params: { pb: pb }
      expect(response).to have_http_status(:no_content)
      expect(Drivers::Go2rtc.playback_owner(pb)).to be_nil
    end

    it "reproduzir: horário futuro ou inválido, câmera sem perfil" do
      travel_to(Time.zone.parse("2026-11-13 12:00")) do
        post "/cameras/#{garagem.id}/reproduzir", params: { inicio: "2026-11-14 10:00" }, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        post "/cameras/#{garagem.id}/reproduzir", params: { inicio: "ontem" }, as: :json
        expect(response).to have_http_status(:unprocessable_content)
      end
      other = within(tenant) { create(:point, device: dvr, name: "Avulsa", capability: "stream", address: { "path" => "/live" }) }
      post "/cameras/#{other.id}/reproduzir", params: { inicio: 1.hour.ago.iso8601 }, as: :json
      expect(response).to have_http_status(:service_unavailable)
    end

    it "MSE: só WebSocket da mesma origem, no limite por pessoa, e entrega a conexão ao proxy" do
      get "/cameras/#{garagem.id}/mse"
      expect(response).to have_http_status(:bad_request)
      get "/cameras/#{garagem.id}/mse", headers: ws_headers.merge("Origin" => "https://malicioso.example")
      expect(response).to have_http_status(:forbidden)
      get "/cameras/#{garagem.id}/mse", headers: ws_headers # sem hijack (servidor que não deixa)
      expect(response).to have_http_status(:not_implemented)

      io = StringIO.new
      allow(Cameras::WsProxy).to receive(:start)
      get "/cameras/#{garagem.id}/mse", headers: ws_headers.merge("Origin" => "http://www.example.com"), env: { "rack.hijack" => -> { io } }
      expect(Cameras::WsProxy).to have_received(:start).with(io, "#{go}/api/ws?src=#{garagem.id}", "dGhlIHNhbXBsZSBub25jZQ==", on_touch: kind_of(Proc), on_close: kind_of(Proc))
      expect(Cameras::Streams.count(user.id)).to eq(1)

      ENV["CAMERA_STREAMS_PER_USER"] = "1"
      get "/cameras/#{garagem.id}/mse", headers: ws_headers, env: { "rack.hijack" => -> { io } }
      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include("até 1")
    ensure
      ENV.delete("CAMERA_STREAMS_PER_USER")
    end

    it "MSE: fecha a vaga quando o proxy termina; sem go2rtc, 503" do
      captured = nil
      allow(Cameras::WsProxy).to receive(:start) { |*_, **kw| captured = kw }
      get "/cameras/#{garagem.id}/mse", headers: ws_headers, env: { "rack.hijack" => -> { StringIO.new } }
      expect(Cameras::Streams.count(user.id)).to eq(1)
      captured[:on_touch].call
      captured[:on_close].call
      expect(Cameras::Streams.count(user.id)).to eq(0)
      ENV["GO2RTC_URL"] = nil
      get "/cameras/#{garagem.id}/mse", headers: ws_headers, env: { "rack.hijack" => -> { StringIO.new } }
      expect(response).to have_http_status(:service_unavailable)
    end

    it "HLS: link assinado; índice, sessão presa ao token e pedaços sem sessão" do
      get "/cameras/#{garagem.id}/hls"
      url = JSON.parse(response.body)["url"]
      expect(url).to match(%r{\A/cameras/#{garagem.id}/hls/[A-Za-z0-9_=-]+/stream\.m3u8\z})
      stub_request(:get, "#{go}/api/stream.m3u8?src=#{garagem.id}&mp4=").to_return(body: "#EXTM3U\nhls/playlist.m3u8?id=Sess1234\n")
      stub_request(:get, "#{go}/api/hls/playlist.m3u8?id=Sess1234").to_return(body: "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4?id=Sess1234\"\nsegment.m4s?id=Sess1234&n=1\n")
      stub_request(:get, "#{go}/api/hls/segment.m4s?id=Sess1234&n=1").to_return(body: "SEG")
      delete "/sair" # sem sessão: o token basta
      get url
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/vnd.apple.mpegurl")
      dir = url.delete_suffix("stream.m3u8")
      get "#{dir}hls/playlist.m3u8?id=Sess1234"
      expect(response.body).to include("segment.m4s")
      get "#{dir}hls/segment.m4s?id=Sess1234&n=1"
      expect(response.body).to eq("SEG")
      expect(response.media_type).to eq("video/iso.segment")
      get "#{dir}hls/segment.m4s?id=OutraSess&n=1"
      expect(response).to have_http_status(:not_found)
      get url.sub("/hls/", "/hls/x")
      expect(response).to have_http_status(:not_found)
    end

    it "HLS: pessoa desativada ou sem papel não abre" do
      get "/cameras/#{garagem.id}/hls"
      url = JSON.parse(response.body)["url"]
      user.update!(disabled_at: Time.current)
      get url
      expect(response).to have_http_status(:not_found)
    end

    it "página do ponto e painel levam o MSE/HLS" do
      get "/pontos/#{garagem.id}"
      expect(response.body).to include("/cameras/#{garagem.id}/mse", "/cameras/#{garagem.id}\"")
    end
  end

  describe "API do app" do
    let(:h) { auth_headers(user) }

    it "lista as câmeras com o que cada uma faz" do
      get "/api/v1/sites/#{site.id}/cameras", headers: h
      expect(response).to have_http_status(:ok)
      expect(data.map { |c| c["name"] }).to eq(%w[Garagem Quintal])
      expect(data.first["features"]).to include("live" => true, "playback" => true, "talk" => false)
    end

    it "HLS do ao vivo, linha do tempo, reproduzir e parar" do
      get "/api/v1/cameras/#{garagem.id}/hls", headers: h
      expect(data["url"]).to start_with("/cameras/#{garagem.id}/hls/")
      stub_request(:get, %r{192\.168\.68\.115/cgi-bin/mediaFileFind\.cgi\?action=factory\.create}).to_raise(Errno::EHOSTUNREACH)
      get "/api/v1/cameras/#{garagem.id}/timeline", params: { day: "2026-11-12" }, headers: h
      expect(data["error"]).to be_present
      stub_request(:put, %r{#{go}/api/streams\?name=pb_}).to_return(status: 400)
      post "/api/v1/cameras/#{garagem.id}/playback", params: { start: 2.hours.ago.iso8601 }, headers: h, as: :json
      expect(response).to have_http_status(:ok)
      expect(data["url"]).to include("/stream.m3u8")
      stub_request(:delete, "#{go}/api/streams?src=#{data['stream']}").to_return(status: 400)
      delete "/api/v1/cameras/#{garagem.id}/playback", params: { stream: data["stream"] }, headers: h
      expect(response).to have_http_status(:no_content)
      post "/api/v1/cameras/#{garagem.id}/playback", params: { start: "x" }, headers: h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "de outra instalação não acha" do
      stranger = create(:user)
      get "/api/v1/cameras/#{garagem.id}/hls", headers: auth_headers(stranger)
      expect(response).to have_http_status(:not_found)
    end
  end
end
