require "rails_helper"

# resto2 (paridade, 2026-11-03): o que sobrou do grupo 9. Aparelhos e
# nuvens de mentira (TLS/TCP em 127.0.0.1, WebMock); nada de rede, conta ou
# aparelho real.
RSpec.describe "Paridade: resto2" do
  let(:tenant) { create(:tenant) }
  let!(:site) { ActsAsTenant.with_tenant(tenant) { create(:site) } }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def form(h = {}) = ActionController::Parameters.new(h)
  def run(point, command, value = nil) = ExecuteCommandJob.perform_now(Points::Command.call(point, command, value, source: "web").id)
  def adopt(i) = Integrations.adopt!(i, i.found.to_h { |e| [ e["id"], "" ] }).then { i.devices.reload }
  def caps(device) = device.points.reload.index_by(&:capability)
  def json(body, status = 200) = { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }

  describe "pareamento com código na tela por plugin (PendingPairing)" do
    it "um plugin falso registrado usa a mesma espera sem mudar o núcleo" do
      session = Struct.new(:closed) { def close = self.closed = true }.new(false)
      fake = Class.new(Integrations::SchemaPlugin) do
        describe key: "teste_tela", title: "Teste Tela", icon: "bolt", description: "Teste"
        field :host, required: true
        field :code
        define_singleton_method(:login) do |i, f|
          i.save!
          f[:code].blank? ? Integrations::PendingPairing.put(i.id, session) : Integrations::PendingPairing.take(i.id)
          outcome(:connect, integration: i, alert: f[:code].presence || "mostre")
        end
      end
      stub_const("Integrations::TesteTelaPlugin", fake)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[TesteTelaPlugin])
      plugin = Integrations.plugin("teste_tela")
      i = plugin.setup(site, form(host: "127.0.0.1")).integration
      expect(Integrations::PendingPairing.take(i.id)).to eq(session)
      plugin.login(i, form)
      plugin.login(i, form) # de novo: a sessão anterior é fechada
      expect(session.closed).to be true
      travel(4.minutes) { expect(Integrations::PendingPairing.take(i.id)).to be_nil }
    end
  end

  describe "Android TV Remote v2 (grupo 9, #16)" do
    let(:plugin) { Integrations::AndroidtvRemotePlugin }
    let!(:tv) { FakeAndroidTv.new }

    after { tv.stop }

    it "pareia com o código da TV (TLS + protobuf), lê o estado e manda teclas e links" do
      o = plugin.setup(site, form(host: "127.0.0.1", port: tv.port.to_s))
      expect([ o.to, o.alert ]).to eq([ :connect, plugin.text(:need_code) ])
      i = o.integration
      expect(i.settings.to_json).not_to include("PRIVATE KEY")
      wrong = format("%02X", tv.code[0, 2].to_i(16) ^ 1) + tv.code[2..]
      expect(plugin.login(i, form(code: wrong)).alert).to eq(plugin.text(:wrong_code))
      o = plugin.login(i.reload, form(code: tv.code.downcase))
      expect(o.alert).to be_nil
      expect(i.reload.found.map { |e| e["name"] }).to eq([ "Teste Fabricante Teste TV" ])

      dev = adopt(i).sole
      plugin.poll(dev)
      media, remote = caps(dev).values_at("media", "remote")
      expect(media.value).to eq("state" => "on", "volume" => 30, "muted" => false, "app" => "com.netflix.ninja")
      expect(tv.pong).to eq(7)
      run(media, "pause")
      run(media, "off")
      run(remote, "send", "home")
      run(media, "play_media", "https://www.netflix.com/title/1")
      expect(tv.keys).to eq([ [ 127, 3 ], [ 223, 3 ], [ 3, 3 ] ])
      expect(tv.links).to eq([ "https://www.netflix.com/title/1" ])
      expect { Points::Command.call(remote, "send", "teclado", source: "web") }.to raise_error(Points::Command::Error)

      # o certificado da TV ficou preso na 1ª sessão: outro no mesmo endereço é recusado
      expect(i.reload.secrets["tv_cert"]).to match(/\A\h{64}\z/)
      i.merge_secrets!("tv_cert" => "0" * 64)
      expect { plugin.entries(i) }.to raise_error(Integrations::Error, /TLS/)
    end

    it "a TV não conversa com um certificado que não pareou" do
      i = site.integrations.create!(driver: "androidtv_remote", name: "Teste TV", settings: { "host" => "127.0.0.1", "port" => tv.port },
                                    credentials: AndroidTvRemote.certificate.merge("paired" => true).to_json)
      expect { plugin.entries(i) }.to raise_error(Integrations::Error, /Android TV/)
      expect(plugin.add_found(site, "host" => "127.0.0.1")).to be_nil
    end
  end

  describe "Apple TV pelo Companion (grupo 9, #22)" do
    let(:plugin) { Integrations::AppleTvPlugin }
    let!(:atv) { FakeAppleTv.new }

    after { atv.stop }

    it "OPACK: lê referências a valores já lidos e escreve o que lê" do
      o = Companion::Opack
      raw = "\xE2".b + o.pack("k1") + o.pack("valor") + o.pack("k2") + "\xA1".b
      expect(o.unpack(raw)).to eq("k1" => "valor", "k2" => "valor")
      big = { "_i" => "x" * 300, "_x" => 70_000, "_c" => { "b" => "\x00\x01".b, "l" => (1..20).to_a, "f" => 1.5, "t" => true, "n" => nil } }
      expect(o.unpack(o.pack(big))).to eq(big)
    end

    it "pareia pelo PIN de 4 dígitos (HAP sobre quadros OPACK), lê o estado e comanda" do
      o = plugin.setup(site, form(host: "127.0.0.1", port: atv.port.to_s))
      expect([ o.to, o.alert, atv.started ]).to eq([ :connect, plugin.text(:need_code), true ])
      i = o.integration
      o = plugin.login(i, form(pin: "1234"))
      expect(o.alert).to be_nil
      expect(i.reload.found.sole["id"]).to eq("appletv:#{FakeHapAccessory::ID}")
      expect(i.settings.to_json).not_to include("ltsk")

      dev = adopt(i).sole
      plugin.poll(dev)
      media, remote = caps(dev).values_at("media", "remote")
      expect(media.value).to eq("state" => "on")
      expect(media.address["apps"]).to include("com.netflix.Netflix" => "Netflix")
      run(media, "off")
      run(media, "pause")
      run(media, "play_media", "com.netflix.Netflix")
      run(remote, "send", "menu")
      expect(atv.hid).to eq([ [ 12, 1 ], [ 12, 2 ], [ 5, 1 ], [ 5, 2 ] ])
      expect([ atv.mcc, atv.launched ]).to eq([ [ 2 ], [ "com.netflix.Netflix" ] ])
      expect(atv.asked).to include("_systemInfo", "_sessionStart")
    end

    it "PIN errado: a Apple TV recusa e nada fica pareado" do
      i = plugin.setup(site, form(host: "127.0.0.1", port: atv.port.to_s)).integration
      expect(plugin.login(i, form(pin: "9999")).alert).to include("código errado")
      expect(i.reload.secrets["pairing"]).to be_nil
      expect(plugin.login(i, form(pin: "1234")).alert).to eq(plugin.text(:expired))
    end
  end

  describe "Xbox pelo Xbox Live (grupo 9, #76)" do
    let(:plugin) { Integrations::XboxPlugin }
    let(:xsts) { { "Token" => "XT", "NotAfter" => 1.hour.from_now.iso8601, "DisplayClaims" => { "xui" => [ { "uhs" => "123" } ] } } }

    before do
      stub_request(:post, Integrations::XboxPlugin::USER_AUTH).with(body: hash_including("Properties" => hash_including("RpsTicket" => /\Ad=A\d\z/)))
                                                               .to_return(json("Token" => "UT"))
      stub_request(:post, Integrations::XboxPlugin::XSTS).with(body: hash_including("Properties" => { "UserTokens" => [ "UT" ], "SandboxId" => "RETAIL" }))
                                                          .to_return(json(xsts))
    end

    def xbl(path) = stub_request(:any, "#{Integrations::XboxPlugin::API}#{path}").with(headers: { "Authorization" => "XBL3.0 x=123;XT", "x-xbl-contract-version" => "4" })

    it "app OAuth do dono → token de usuário → XSTS → consoles, estado e comandos; 401 renova uma vez" do
      xbl("/lists/devices?queryCurrentDevice=false&includeStorageDevices=true")
        .to_return(json("result" => [ { "id" => "FD00", "name" => "Teste Xbox", "consoleType" => "XboxSeriesX", "powerState" => "On" } ]))
      o = plugin.setup(site, form(client_id: "cid-teste", client_secret: "csec-teste"))
      expect(o.to).to eq(:connect)
      i = o.integration
      expect(plugin.connect_locals(i, { redirect_uri: "https://ma.exemplo/r" })[:auth_url]).to include("login.live.com", "Xboxlive.signin")
      stub_request(:post, plugin.oauth_config[:token]).with(body: hash_including("grant_type" => "authorization_code", "code" => "C1"))
                                                      .to_return(json("access_token" => "A1", "refresh_token" => "R-teste", "expires_in" => 3600))
      expect(plugin.oauth_callback(i, { code: "C1", redirect_uri: "https://ma.exemplo/r" }).alert).to be_nil
      expect(i.reload.settings.to_json).not_to include("XT", "csec-teste")

      xbl("/consoles/FD00").to_return(json({}, 401), json("powerState" => "On", "focusAppAumid" => "Teste.Netflix", "playbackState" => "Playing"))
      stub_request(:post, plugin.oauth_config[:token]).with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "R-teste"))
                                                      .to_return(json("access_token" => "A2", "refresh_token" => "R-teste", "expires_in" => 3600))
      dev = adopt(i).sole # a adoção já lê: o 1º 401 renova o XSTS
      plugin.poll(dev)
      media, remote = caps(dev).values_at("media", "remote")
      expect(media.value).to eq("state" => "on", "app" => "Teste.Netflix", "playback" => "Playing")
      expect(i.reload.secrets["access_token"]).to eq("A2")

      xbl("/consoles/FD00").to_return(json("powerState" => "ConnectedStandby"))
      bodies = []
      xbl("/commands").to_return do |req|
        bodies << JSON.parse(req.body)
        json({})
      end
      run(media, "off")
      run(media, "volume_up")
      run(media, "play_media", "9WZDNCRFJ3TJ")
      run(remote, "send", "A")
      expect(media.reload.value).to eq("state" => "off")
      expect(bodies.map { |b| [ b["type"], b["command"], b["parameters"] ] }).to eq([ [ "Power", "TurnOff", [ {} ] ], [ "Audio", "Volume", [ { "direction" => "Up", "amount" => 1 } ] ],
                                                                                     [ "Shell", "ActivateApplicationWithOneStoreProductId", [ { "oneStoreProductId" => "9WZDNCRFJ3TJ" } ] ],
                                                                                     [ "Shell", "InjectKey", [ { "keyType" => "A" } ] ] ])
      expect(bodies.map { |b| b["linkedXboxId"] }.uniq).to eq([ "FD00" ])
    end

    it "conta sem perfil Xbox: o XSTS recusa com a explicação" do
      stub_request(:post, Integrations::XboxPlugin::XSTS).to_return(json({ "XErr" => 2_148_916_233 }, 401))
      i = site.integrations.create!(driver: "xbox", name: "Teste Xbox", credentials: { "access_token" => "A1", "expires_at" => 1.hour.from_now.to_i }.to_json)
      expect { plugin.entries(i) }.to raise_error(Integrations::Error, plugin.text(:no_profile))
    end
  end

  describe "Roborock pela nuvem (grupo 9, #34)" do
    let(:plugin) { Integrations::RoborockPlugin }
    let(:key) { "chave-local-123" }
    let(:base) { "https://usiot.roborock.com" }
    let(:rriot) { { "u" => "uTeste", "s" => "sTeste", "h" => "hTeste", "k" => "kTeste", "r" => { "a" => "https://api-us.roborock.com", "m" => "tcp://127.0.0.1:#{broker.port}" } } }
    let!(:broker) { FakeRoborockMqtt.new(local_key: key, user: Roborock.mqtt_user("u" => "uTeste", "k" => "kTeste"), pass: Roborock.mqtt_pass("s" => "sTeste", "k" => "kTeste")) }

    after { broker.stop }

    it "protocolo 1.0: carimbo embaralhado, AES com a chave local e CRC" do
      expect(Roborock.encode_ts(0x12345678)).to eq("67482315")
      msg = Roborock.encode(key, 101, '{"a":1}', ts: 0x12345678)
      expect(Roborock.decode(key, msg)).to eq([ 101, '{"a":1}' ])
      bad = msg.dup.tap { |m| m.setbyte(20, m.getbyte(20) ^ 1) }
      expect { Roborock.decode(key, bad) }.to raise_error(Roborock::Error, /CRC/)
      expect { Roborock.decode("outra", msg) }.to raise_error(Roborock::Error, /chave/)
    end

    it "login com o código do e-mail, robôs e cômodos pela API (Hawk), estado e comandos pelo MQTT" do
      stub_request(:post, "https://euiot.roborock.com/api/v1/getUrlByEmail?email=teste@exemplo.com").with(headers: { "header_clientid" => %r{\A[A-Za-z0-9+/=]{24}\z} })
                                                                                                    .to_return(json("code" => 200, "data" => { "url" => base }))
      code = stub_request(:post, "#{base}/api/v1/sendEmailCode?type=auth&username=teste@exemplo.com").to_return(json("code" => 200))
      o = plugin.setup(site, form(username: "teste@exemplo.com"))
      expect([ o.to, o.alert ]).to eq([ :connect, plugin.text(:need_code) ])
      expect(code).to have_been_requested
      i = o.integration

      stub_request(:post, "#{base}/api/v1/loginWithCode?username=teste@exemplo.com&verifycode=123456&verifycodetype=AUTH_EMAIL_CODE")
        .to_return(json("code" => 200, "data" => { "token" => "tok-teste", "rriot" => rriot }))
      stub_request(:get, "#{base}/api/v1/getHomeDetail").with(headers: { "Authorization" => "tok-teste" }).to_return(json("code" => 200, "data" => { "rrHomeId" => 77 }))
      hawk_ok = lambda do |req|
        h = req.headers["Authorization"].to_s.scan(/(\w+)="([^"]*)"/).to_h
        pre = [ "uTeste", "sTeste", h["nonce"], h["ts"], Digest::MD5.hexdigest("/user/homes/77"), "", "" ].join(":")
        h["id"] == "uTeste" && h["mac"] == Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", "hTeste", pre))
      end
      stub_request(:get, "https://api-us.roborock.com/user/homes/77").with(&hawk_ok)
        .to_return(json("success" => true, "result" => { "devices" => [ { "duid" => "d1", "name" => "Teste Robô", "localKey" => key, "productId" => "p1" } ],
                                                         "products" => [ { "id" => "p1", "model" => "roborock.vacuum.a15", "name" => "S7" } ],
                                                         "rooms" => [ { "id" => 501, "name" => "Cozinha" }, { "id" => 502, "name" => "Sala" } ] }))
      o = plugin.login(i, form(code: "123456"))
      expect(o.alert).to be_nil
      entry = i.reload.found.sole
      expect(entry).to include("name" => "Teste Robô", "model" => "roborock.vacuum.a15")
      expect(entry["points"].first.dig("address", "rooms")).to eq([ { "id" => 16, "name" => "Cozinha" }, { "id" => 17, "name" => "Sala" } ])
      expect(i.settings.to_json).not_to include("kTeste", "tok-teste")

      dev = adopt(i).sole
      expect(dev.credential).to eq(key)
      plugin.poll(dev)
      pts = dev.points.reload.index_by { |p| p.address["field"] }
      expect(pts.transform_values(&:value)).to eq("vacuum" => "cleaning", "battery" => 87, "fan" => "Turbo", "area" => 12.5, "duration" => 20, "error" => false)
      run(pts["vacuum"], "clean_rooms", { "rooms" => [ "Sala" ] })
      run(pts["vacuum"], "home")
      run(pts["fan"], "select", "Máxima")
      expect(broker.calls).to include([ "app_segment_clean", [ { "segments" => [ 17 ], "repeat" => 1 } ] ], [ "app_charge", [] ], [ "set_custom_mode", [ 104 ] ])
      user = Roborock.mqtt_user(rriot)
      expect(broker.topics).to include("rr/m/o/uTeste/#{user}/d1", "rr/m/i/uTeste/#{user}/d1")
    end
  end
end
