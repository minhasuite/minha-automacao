require "rails_helper"

# appweb2: o que o app nativo precisava do servidor para fechar a Onda D —
# câmera ao vivo (WebRTC), pipelines e palavra de ativação no celular,
# sensores com permissão e geofence (zonas), passkey pelo Credential Manager
# do Android e envio de arquivo pelo seletor nativo nas telas do servidor.
RSpec.describe "App nativo: Onda D completa (appweb2)" do
  let(:user) { create(:user, name: "Teste Ana") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Teste Casa", latitude: -15.79, longitude: -47.88) } }
  let(:h) { auth_headers(user) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  describe "D3 câmera ao vivo" do
    let(:camera) do
      d = create(:device, site: site, driver: "go2rtc", name: "Teste Câmera", address: { "host" => "192.168.0.12" })
      create(:point, device: d, site: site, name: "Ao vivo", capability: "stream", address: { "path" => "/live" })
    end

    before { ENV["GO2RTC_URL"] = "http://go2rtc:1984" }
    after { ENV.delete("GO2RTC_URL") }

    it "troca a oferta SDP do app pela resposta do go2rtc" do
      stub_request(:post, "http://go2rtc:1984/api/webrtc?src=#{camera.id}").with(body: "v=0 oferta").to_return(body: "v=0 resposta")
      post "/api/v1/points/#{camera.id}/webrtc", params: "v=0 oferta", headers: h.merge("CONTENT_TYPE" => "application/sdp")
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("v=0 resposta")
      expect(response.media_type).to eq("application/sdp")
    end

    it "recusa o que não é SDP e câmera de outra casa" do
      post "/api/v1/points/#{camera.id}/webrtc", params: "oi", headers: h.merge("CONTENT_TYPE" => "application/sdp")
      expect(response).to have_http_status(:unprocessable_content)
      outsider = create(:user)
      post "/api/v1/points/#{camera.id}/webrtc", params: "v=0 x", headers: auth_headers(outsider).merge("CONTENT_TYPE" => "application/sdp")
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "D5 pipelines e palavra de ativação" do
    # Motor de ativação falso, registrado sem mudar o núcleo.
    let!(:engine) do
      klass = Class.new(Assist::Engines::Base) do
        describe key: "teste_wake", label: "Ativação de teste", kinds: %i[wake], fields: [ [ "names", :text ] ]
        texts en: { label: "Test wake" }, es: { label: "Activación de prueba" }
        def self.check(_cfg, _kind) = []
        def self.detect(cfg, audio:, **) = audio.include?("ok casa") ? cfg["names"] : nil
      end
      stub_const("Assist::Engines::TesteWake", klass)
      stub_const("Assist::Engines::PLUGINS", Assist::Engines::PLUGINS + %w[TesteWake])
      klass
    end
    let!(:sem_wake) { AssistPipeline.create!(site: site, name: "Teste só texto", preferred: true) }
    let!(:com_wake) { AssistPipeline.create!(site: site, name: "Teste com palavra", wake: { "engine" => "teste_wake", "names" => "ok_casa" }) }

    def audio(text) = Rack::Test::UploadedFile.new(StringIO.new("RIFF....WAVE#{text}"), "audio/wav", original_filename: "w.wav")

    it "lista os pipelines e diz quem ouve a palavra" do
      get "/api/v1/sites/#{site.id}/assist/pipelines", headers: h
      list = response.parsed_body["data"]
      expect(list.map { |p| [ p["name"], p["preferred"], p["wake"] ] }).to eq([ [ "Teste só texto", true, false ], [ "Teste com palavra", false, true ] ])
      expect(list.last["wake_names"]).to eq([ "ok_casa" ])
    end

    it "detecta a palavra pelo motor do pipeline escolhido" do
      post "/api/v1/sites/#{site.id}/assist/wake", params: { audio: audio("ok casa"), pipeline_id: com_wake.id }, headers: h
      expect(response.parsed_body["data"]).to eq("detected" => true, "name" => "ok_casa")
      post "/api/v1/sites/#{site.id}/assist/wake", params: { audio: audio("barulho"), pipeline_id: com_wake.id }, headers: h
      expect(response.parsed_body["data"]).to eq("detected" => false, "name" => nil)
      post "/api/v1/sites/#{site.id}/assist/wake", params: { audio: audio("ok casa") }, headers: h # o preferido não tem
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("wake_unavailable")
    end
  end

  describe "D1 sensores com permissão e geofence" do
    def phone
      post "/api/v1/sites/#{site.id}/mobile_devices", params: { install_id: "teste-appweb2-1", name: "Teste Pixel" }, headers: h
      response.parsed_body["data"]
    end

    it "passos, atividade, Bluetooth, chamada e luz viram pontos" do
      id = phone["id"]
      post "/api/v1/mobile_devices/#{id}/sensors", params: { steps: "4210", activity: "andando", bluetooth: "true", bt_devices: [ "Fone", "Carro" ], call: "tocando", light: "180.4" }, headers: h, as: :json
      values = response.parsed_body.dig("data", "points").to_h { |p| [ p["name"], p["value"] ] }
      expect(values).to include("Passos" => 4210, "Atividade" => "andando", "Bluetooth" => true, "Bluetooth conectado" => "Fone, Carro", "Chamada" => "tocando", "Luz ambiente" => 180)
      post "/api/v1/mobile_devices/#{id}/sensors", params: { activity: "voando" }, headers: h, as: :json
      expect(response.parsed_body.dig("data", "points").find { |p| p["name"] == "Atividade" }["value"]).to eq("andando") # valor fora da lista não entra
    end

    it "manda a casa e as zonas (centro e raio) para o geofence do celular" do
      zone = HelperTypes.build(site, HelperTypes::Zone)
      HelperTypes.save(zone, "name" => "Teste Trabalho", "latitude" => "-15,7", "longitude" => "-47,8", "radius_m" => "300")
      zones = phone["zones"]
      expect(zones.first).to include("id" => "home", "latitude" => -15.79, "longitude" => -47.88, "radius" => 150)
      expect(zones.last).to include("name" => "Teste Trabalho", "latitude" => -15.7, "longitude" => -47.8, "radius" => 300.0)
    end
  end

  describe "passkey pelo Credential Manager do Android" do
    let(:print) { ([ "AB" ] * 32).join(":") }
    let(:key) { OpenSSL::PKey::EC.generate("prime256v1") }
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }

    before do
      ENV["ANDROID_APP_CERT_SHA256"] = print
      allow(Rails).to receive(:cache).and_return(cache)
    end

    after { ENV.delete("ANDROID_APP_CERT_SHA256") }

    def b64(bin) = Passkeys.b64(bin)
    def auth_data(count) = Digest::SHA256.digest("www.example.com") + [ 0x05 ].pack("C") + [ count ].pack("N")
    def client(type, challenge, origin = Passkeys.android_origins.first) = b64({ type: type, challenge: challenge, origin: origin }.to_json)

    it "publica o assetlinks com o pacote e a impressão do certificado" do
      get "/.well-known/assetlinks.json"
      body = response.parsed_body
      expect(body.first["target"]).to include("package_name" => "com.minhasuite.minhaautomacao", "sha256_cert_fingerprints" => [ print ])
      expect(body.first["relation"]).to include("delegate_permission/common.get_login_creds")
      expect(Passkeys.android_origins).to eq([ "android:apk-key-hash:#{b64([ 'AB' * 32 ].pack('H*'))}" ])
    end

    it "cria a passkey no app e entra com ela (tokens novos)" do
      get "/api/v1/me/passkeys/options", headers: h
      opts = response.parsed_body["data"]
      expect(opts.dig("rp", "id")).to eq("www.example.com")
      cred = { id: "cred-teste-1", response: { clientDataJSON: client("webauthn.create", opts["challenge"]), authenticatorData: b64(auth_data(0)), publicKey: b64(key.public_to_der) } }
      post "/api/v1/me/passkeys", params: { credential: cred, name: "Teste Pixel" }, headers: h, as: :json
      expect(response).to have_http_status(:created)
      expect(user.passkeys.pluck(:name)).to eq([ "Teste Pixel" ])

      post "/api/v1/auth/passkey/options", as: :json
      d = response.parsed_body["data"]
      cdj = client("webauthn.get", d.dig("options", "challenge"))
      sig = key.sign("SHA256", auth_data(1) + Digest::SHA256.digest(Passkeys.unb64(cdj)))
      post "/api/v1/auth/passkey", params: { challenge_id: d["challenge_id"], credential: { id: "cred-teste-1", response: { clientDataJSON: cdj, authenticatorData: b64(auth_data(1)), signature: b64(sig) } } }, as: :json
      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "access_token")).to be_present

      # O desafio é de uso único.
      post "/api/v1/auth/passkey", params: { challenge_id: d["challenge_id"], credential: { id: "cred-teste-1", response: { clientDataJSON: cdj, authenticatorData: b64(auth_data(2)), signature: b64(sig) } } }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "recusa a origem de outro app ou do navegador" do
      get "/api/v1/me/passkeys/options", headers: h
      ch = response.parsed_body.dig("data", "challenge")
      cred = { id: "cred-x", response: { clientDataJSON: client("webauthn.create", ch, "android:apk-key-hash:outro"), authenticatorData: b64(auth_data(0)), publicKey: b64(key.public_to_der) } }
      post "/api/v1/me/passkeys", params: { credential: cred }, headers: h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(user.passkeys).to be_empty
    end
  end

  describe "envio de arquivo pelo seletor nativo (tela do servidor)" do
    it "o arquivo chega à tela da web como o navegador mandaria" do
      got = {}
      allow(Backups::Restore).to receive(:allowed?).and_return(true)
      allow(Backups::Restore).to receive(:upload!) { |f, passphrase:| got.merge!(name: f.original_filename, body: f.read, pass: passphrase) && "teste.sql.gz" }
      allow(Backups::Restore).to receive(:start!)
      file = Rack::Test::UploadedFile.new(StringIO.new("conteúdo do backup"), "application/gzip", original_filename: "teste.sql.gz")
      fields = [ [ "confirm", I18n.t("backup_restore.word") ], [ "passphrase", "segredo-teste" ] ].to_json
      post "/api/v1/screen", params: { path: "/configuracoes/backups", method: "post", fields: fields, files: { "file" => file } }, headers: h
      expect(response).to have_http_status(:ok)
      expect(got).to eq(name: "teste.sql.gz", body: "conteúdo do backup".b, pass: "segredo-teste")
      expect(Backups::Restore).to have_received(:start!).with("teste.sql.gz", source: "storage", user: user)
    end

    it "o corpo multipart separa campos e arquivo" do
      file = Rack::Test::UploadedFile.new(StringIO.new("abc"), "text/plain", original_filename: "a\"b.txt")
      type, body = AppScreen.multipart([ %w[x 1], [ "y[]", "2" ] ], { "doc" => file })
      env = Rack::MockRequest.env_for("/", method: "POST", input: body, "CONTENT_TYPE" => type)
      parsed = Rack::Multipart.parse_multipart(env)
      expect(parsed["x"]).to eq("1")
      expect(parsed["y"]).to eq([ "2" ])
      expect(parsed["doc"][:filename]).to eq("ab.txt")
      expect(parsed["doc"][:tempfile].read).to eq("abc")
    end
  end
end
