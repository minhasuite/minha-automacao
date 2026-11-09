require "rails_helper"

module TapoSpec
  # Câmera de mentira da API local: login em dois passos, sessão cifrada e estado.
  class FakeCamera
    attr_reader :state, :log

    def initialize(password, mode: :secure)
      @hashed = OpenSSL::Digest::SHA256.hexdigest(password).upcase
      @md5 = OpenSSL::Digest::MD5.hexdigest(password).upcase
      @mode = mode
      @nonce = "ABCDEF0123456789"
      @seq = 10
      @state = { "privacy" => "off", "led" => "on", "motion" => "on", "alarm" => nil }
      @log = []
    end

    def sha(s) = OpenSSL::Digest::SHA256.hexdigest(s).upcase
    def json(h) = { status: 200, body: h.to_json, headers: { "Content-Type" => "application/json" } }

    def call(req)
      body = JSON.parse(req.body)
      req.uri.path == "/" ? login(body) : ds(req, body)
    end

    def login(body)
      p = body["params"]
      return json(error_code: -40211) if @mode == :tpap
      return legacy(p) if @mode == :legacy
      return json(error_code: -40413, result: { data: { encrypt_type: %w[3], nonce: @nonce, device_confirm: sha(p["cnonce"] + @hashed + @nonce) + @nonce + p["cnonce"] } }) unless p["digest_passwd"]

      @cnonce = p["cnonce"]
      return json(error_code: -40411) unless p["digest_passwd"] == sha(@hashed + @cnonce + @nonce) + @cnonce + @nonce

      key = sha(@cnonce + @hashed + @nonce)
      @lsk = OpenSSL::Digest::SHA256.digest("lsk#{@cnonce}#{@nonce}#{key}").byteslice(0, 16)
      @ivb = OpenSSL::Digest::SHA256.digest("ivb#{@cnonce}#{@nonce}#{key}").byteslice(0, 16)
      json(error_code: 0, result: { stok: "STOK1", start_seq: @seq, user_group: "root" })
    end

    def legacy(p)
      return json(error_code: -40413, result: { data: { encrypt_type: %w[1] } }) unless p["hashed"]

      p["password"] == @md5 ? json(error_code: 0, result: { stok: "OLD" }) : json(error_code: -40411)
    end

    def ds(req, body)
      return json(answer(body)) if @mode == :legacy

      raise "Seq" unless req.headers["Seq"] == @seq.to_s
      raise "Tapo_tag" unless req.headers["Tapo-Tag"] == sha(sha(@hashed + @cnonce) + req.body + @seq.to_s)

      @seq += 1
      inner = JSON.parse(crypt(:decrypt, Base64.decode64(body.dig("params", "request"))))
      json(error_code: 0, result: { response: Base64.strict_encode64(crypt(:encrypt, answer(inner).to_json)) })
    end

    def crypt(mode, data)
      c = OpenSSL::Cipher.new("aes-128-cbc").public_send(mode)
      c.key = @lsk
      c.iv = @ivb
      c.update(data) + c.final
    end

    def answer(inner)
      @log << inner
      if inner["method"] == "do"
        @state["alarm"] = inner.dig("msg_alarm", "manual_msg_alarm", "action")
        return { error_code: 0, result: {} }
      end
      r = inner.dig("params", "requests").map { |q| { method: q["method"], error_code: 0, result: result(q["method"], q["params"]) } }
      { error_code: 0, result: { responses: r } }
    end

    def result(method, params)
      case method
      when "getLensMaskConfig" then { lens_mask: { lens_mask_info: { enabled: @state["privacy"] } } }
      when "getLedStatus" then { led: { config: { enabled: @state["led"] } } }
      when "getDetectionConfig" then { motion_detection: { motion_det: { enabled: @state["motion"] } } }
      when "setLensMaskConfig" then (@state["privacy"] = params.dig("lens_mask", "lens_mask_info", "enabled")) && {}
      when "setLedStatus" then (@state["led"] = params.dig("led", "config", "enabled")) && {}
      else {}
      end
    end
  end
end

# Câmera TP-Link Tapo (TapoPlugin, Tapo, Tapo::Client). Nada sai para a
# rede: o ONVIF (porta 2020) e a API local (HTTPS 443) são uma câmera de
# mentira no WebMock, que faz o login seguro (encrypt_type 3) de verdade.
RSpec.describe "Câmera Tapo" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, name: "Casa") }
  let(:plugin) { Integrations::TapoPlugin }
  let(:host) { "10.0.0.30" }
  let(:onvif) { "http://#{host}:2020/onvif/device_service" }
  let(:media) { "http://#{host}:2020/onvif/service" }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def soap(body) = %(<?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body>#{body}</s:Body></s:Envelope>)

  # ONVIF da Tapo: dois perfis (stream1/stream2), PTZ e eventos no mesmo serviço.
  def stub_onvif(model: "C200")
    stub_request(:post, onvif).with(body: /GetSystemDateAndTime/).to_return(body: soap("<r/>"))
    stub_request(:post, onvif).with(body: /GetDeviceInformation/).to_return(body: soap("<x><tt:Manufacturer>tp-link</tt:Manufacturer><tt:Model>#{model}</tt:Model><tt:SerialNumber>1</tt:SerialNumber></x>"))
    stub_request(:post, onvif).with(body: /GetCapabilities/).to_return(body: soap(
      "<tt:Capabilities><tt:Media><tt:XAddr>#{media}</tt:XAddr></tt:Media><tt:Events><tt:XAddr>#{media}</tt:XAddr></tt:Events><tt:PTZ><tt:XAddr>#{media}</tt:XAddr></tt:PTZ></tt:Capabilities>"
    ))
    stub_request(:post, media).with(body: /GetEventProperties/).to_return(body: soap("<r/>"))
    stub_request(:post, media).with(body: /GetProfiles/).to_return(body: soap(
      %(<r><Profiles token="profile_1"><tt:Name>mainStream</tt:Name></Profiles><Profiles token="profile_2"><tt:Name>minorStream</tt:Name></Profiles></r>)
    ))
    stub_request(:post, media).with(body: /ProfileToken>profile_1</).to_return(body: soap("<r><MediaUri><tt:Uri>rtsp://#{host}:554/stream1</tt:Uri></MediaUri></r>"))
    stub_request(:post, media).with(body: /ProfileToken>profile_2</).to_return(body: soap("<r><MediaUri><tt:Uri>rtsp://#{host}:554/stream2</tt:Uri></MediaUri></r>"))
  end

  def fake_camera(password = "nuvem", mode: :secure)
    cam = TapoSpec::FakeCamera.new(password, mode: mode)
    stub_request(:post, %r{\Ahttps://#{host}(:443)?/}).to_return { |req| cam.call(req) }
    cam
  end

  def form(**extra) = ActionController::Parameters.new({ host: host, username: "conta", password: "rtsp-senha" }.merge(extra))

  describe "Tapo.preset (config/device_maps/tapo.yml)" do
    it "acha a família pelo prefixo mais longo e cai no padrão fora da lista" do
      expect(Tapo.preset("C200")).to include("ptz" => true, "siren" => true, "spotlight" => false, "rtsp" => true)
      expect(Tapo.preset("Tapo C520WS")).to include("ptz" => true, "spotlight" => true)
      expect(Tapo.preset("C320WS")).to include("ptz" => false, "spotlight" => true)
      expect(Tapo.preset("C410")).to include("rtsp" => false)
      expect(Tapo.preset("C246D")["streams"].pluck("path")).to eq(%w[/stream6 /stream7])
      expect(Tapo.preset("X9")).to eq(Tapo::MAP["default"])
    end
  end

  describe "plugin" do
    it "está no catálogo, acha pelo nome que a Tapo dá ao roteador e guarda as senhas cifradas" do
      expect(Integrations.plugin("tapo")).to eq(plugin)
      expect(plugin.port).to eq(2020)
      expect(Host.dhcp_match?(plugin.dhcp.first, { "hostname" => "c200_a1b2", "mac" => "" })).to be true
      expect(Host.dhcp_match?(plugin.dhcp.first, { "hostname" => "notebook", "mac" => "" })).to be false

      stub_onvif
      o = plugin.setup(site, form(cloud_password: "nuvem"))
      expect(o.to).to eq(:found)
      expect(o.integration.settings).to include("host" => host, "port" => 2020, "username" => "conta")
      expect(o.integration.settings.to_json).not_to include("rtsp-senha", "nuvem")
      expect(o.integration.secrets).to eq("password" => "rtsp-senha", "cloud_password" => "nuvem")
    end

    it "lê a câmera pelo ONVIF da porta 2020 e marca o que o modelo tem" do
      stub_onvif
      i = plugin.setup(site, form).integration
      e = i.found.first
      expect(e).to include("id" => "tapo:#{host}", "kind" => "go2rtc", "manufacturer" => "TP-Link", "model" => "C200", "name" => "Tapo C200")
      expect(e["address"]).to include("host" => host, "port" => 554, "username" => "conta", "onvif_port" => 2020)
      expect(e["address"]["features"]).to include("ptz" => true, "siren" => true)
      high, low = e["points"].select { |p| p["capability"] == "stream" }
      expect(high).to include("name" => "Vídeo (alta)")
      expect(high["address"]).to include("path" => "/stream1", "supports" => %w[record ptz])
      expect(low).to include("name" => "Vídeo (baixa)")
      expect(e["points"].pluck("capability")).to include("motion")
      expect(e["points"].pluck("address").pluck("tapo").compact).to be_empty # sem senha da nuvem, sem controle
      expect(e).not_to have_key("poll_s")
    end

    it "com a senha da nuvem: fala no vídeo principal (tapo://) e, marcado, os pontos de controle" do
      stub_onvif
      i = plugin.setup(site, form(cloud_password: "nuvem", control: "1")).integration
      e = i.found.first
      high, low = e["points"].select { |p| p["capability"] == "stream" }
      expect(high["address"]).to include("talk" => true, "supports" => %w[record ptz play_media])
      expect(low["address"]["supports"]).not_to include("play_media")
      controls = e["points"].select { |p| p.dig("address", "tapo") }
      expect(controls.map { |p| [ p["name"], p["risk"] ] }).to eq([ [ "Modo privacidade", "normal" ], [ "LED de status", "normal" ],
                                                                     [ "Detecção de movimento", "normal" ], [ "Sirene", "critical" ] ])
      expect(e["poll_s"]).to eq(300)

      FeatureFlag.find_or_create_by!(key: "tapo_control").update!(enabled: false)
      expect(Integrations.sync!(i)).to include(found: 1)
      expect(i.reload.found.first["points"].pluck("address").pluck("tapo").compact).to be_empty
    end

    it "lente tele das duas lentes entra pelo mapa; modelo sem RTSP e conta faltando avisam" do
      stub_onvif(model: "C246D")
      e = plugin.setup(site, form).integration.found.first
      expect(e["points"].select { |p| p["capability"] == "stream" }.map { |p| p.dig("address", "path") }).to eq(%w[/stream1 /stream2 /stream6 /stream7])

      stub_onvif(model: "C420")
      expect(plugin.setup(site, form).alert).to match(/C420.*RTSP/)
      expect(plugin.setup(site, form(username: "")).alert).to match(/conta da câmera/)
      WebMock.reset!
      stub_request(:post, onvif).to_raise(Errno::ECONNREFUSED)
      expect(plugin.setup(site, form).alert).to match(/porta 2020/)
    end
  end

  describe "aparelho adotado" do
    def adopt(**extra)
      stub_onvif
      i = plugin.setup(site, form(**extra)).integration
      allow(Drivers).to receive(:refresh)
      Integrations.adopt!(i, "tapo:#{host}" => "")
      site.devices.find_by!(external_id: "tapo:#{host}")
    end

    it "o go2rtc recebe o RTSP com a conta da câmera e, com a senha da nuvem, o tapo:// junto" do
      d = adopt(cloud_password: "n/v@m")
      expect(d).to have_attributes(driver: "go2rtc", credential: "rtsp-senha")
      high = d.points.find_by!(name: "Vídeo (alta)")
      low = d.points.find_by!(name: "Vídeo (baixa)")
      expect(Drivers::Go2rtc.sources(high)).to eq([ "rtsp://conta:rtsp-senha@#{host}:554/stream1", "tapo://n%2Fv%40m@#{host}" ])
      expect(Drivers::Go2rtc.sources(low)).to eq("rtsp://conta:rtsp-senha@#{host}:554/stream2")
      expect(Onvif::Listener.motion_points.pluck(:device_id)).to include(d.id)

      ENV["GO2RTC_URL"] = "http://go2rtc:1984"
      stub_request(:get, "http://go2rtc:1984/api/streams").to_return(body: { high.id => { "producers" => [ { "url" => Drivers::Go2rtc.source(high) } ] } }.to_json)
      stub_request(:put, %r{\Ahttp://go2rtc:1984/api/streams}).to_return(status: 400)
      allow(Drivers::Go2rtc).to receive(:request).and_call_original
      expect(Drivers::Go2rtc.sync!).to eq(2)
      expect(Drivers::Go2rtc).to have_received(:request).with(Net::HTTP::Put, "/api/streams", { name: high.id, src: Drivers::Go2rtc.sources(high) }, ok: [ 400 ])
      expect(Drivers::Go2rtc).to have_received(:request).with(Net::HTTP::Put, "/api/streams", { name: low.id, src: Drivers::Go2rtc.sources(low) }, ok: [ 400 ])
      # o PUT do go2rtc aceita várias fontes repetindo `src` (internal/streams/api.go)
      expect(URI.encode_www_form(src: %w[a b])).to eq("src=a&src=b")
    ensure
      ENV.delete("GO2RTC_URL")
    end

    it "privacidade, LED e sirene pela API local cifrada; a leitura periódica traz o estado" do
      d = adopt(cloud_password: "nuvem", control: "1")
      cam = fake_camera
      expect(d.poll_s).to eq(300)
      expect(Polling.supported?(d)).to be true

      Drivers::Camera.poll(d)
      privacy = d.points.find_by!(name: "Modo privacidade")
      expect(privacy.reload.value).to be false
      expect(d.points.find_by!(name: "LED de status").value).to be true

      run = ->(p, cmd) { ExecuteCommandJob.perform_now(Points::Command.call(p, cmd, nil, source: "web").id) }
      run.(privacy, "on")
      expect(cam.state["privacy"]).to eq("on")
      expect(privacy.reload.value).to be true
      run.(privacy, "toggle")
      expect(cam.state["privacy"]).to eq("off")

      siren = d.points.find_by!(name: "Sirene")
      expect(siren.risk).to eq("critical")
      run.(siren, "on")
      expect(cam.state["alarm"]).to eq("start")
      expect(cam.log.last).to eq("method" => "do", "msg_alarm" => { "manual_msg_alarm" => { "action" => "start" } })
      expect(siren.reload.value).to be true
    end

    it "leitura que falha deixa só os controles indisponíveis; sem integração, a câmera não lê nada" do
      d = adopt(cloud_password: "nuvem", control: "1")
      stub_request(:post, %r{\Ahttps://#{host}}).to_raise(Errno::EHOSTUNREACH)
      expect(Polling.poll_device(d.id)).to be false
      expect(d.points.reload.select { |p| p.quality == "unavailable" }.map(&:name)).to contain_exactly("Modo privacidade", "LED de status", "Detecção de movimento", "Sirene")

      other = create(:device, site: site, driver: "go2rtc", address: { "host" => "10.0.0.99" })
      expect(Drivers::Camera.poll(other)).to be_nil
      cmd = create(:point, device: other, site: site, name: "X", capability: "onoff", writable: true)
      expect { Drivers::Camera.new.execute(cmd, "on", nil) }.to raise_error(Integrations::Error, /não tem comando/)
    end
  end

  describe "Tapo::Client" do
    it "login seguro: confere a câmera, entra e cifra os pedidos com Seq e Tapo_tag" do
      cam = fake_camera
      c = Tapo.client(host, "nuvem")
      expect(Tapo.read(c, %w[privacy led motion_detection siren])).to eq("privacy" => false, "led" => true, "motion_detection" => true)
      Tapo.write(c, "led", false)
      expect(cam.state["led"]).to eq("off")
    end

    it "senha da nuvem errada é erro de credencial; firmware só TPAP pede a Compatibilidade com terceiros" do
      fake_camera("outra")
      expect { Tapo.client(host, "nuvem").login! }.to raise_error(Integrations::AuthError)
      WebMock.reset!
      fake_camera(mode: :tpap)
      expect { Tapo.client(host, "nuvem").login! }.to raise_error(Tapo::Error, /Compatibilidade com terceiros/)
    end

    it "firmware antigo: login com MD5 e pedidos às claras" do
      cam = fake_camera(mode: :legacy)
      c = Tapo.client(host, "nuvem")
      expect(Tapo.read(c, %w[privacy])).to eq("privacy" => false)
      Tapo.write(c, "siren", false)
      expect(cam.state["alarm"]).to eq("stop")
    end
  end
end
