require "rails_helper"

# Pacote 1: mídia na rede (Chromecast, LG webOS, Samsung Tizen, Android TV
# por ADB). Cada protocolo fala com um servidor falso local (TLS com
# certificado gerado aqui, WebSocket pelo websocket-driver do lado servidor,
# ADB com chave verificada) ou WebMock; nunca com aparelho de verdade. Os
# plugins entram por stub_const nos registros, como qualquer extensão.
RSpec.describe "Pacote 1: mídia na rede" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:servers) { [] }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  before do
    stub_const("Drivers::REGISTRY", Drivers::REGISTRY.merge("cast" => "Drivers::Cast", "webos" => "Drivers::Webos", "tizen" => "Drivers::Tizen", "adb" => "Drivers::Adb"))
    stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[CastPlugin WebosPlugin TizenPlugin AdbPlugin])
    stub_const("Polling::DEVICES", Polling::DEVICES.merge("cast" => "Drivers::Cast", "webos" => "Drivers::Webos", "tizen" => "Drivers::Tizen", "adb" => "Drivers::Adb"))
  end

  after { servers.each { |s| s.close rescue nil } } # rubocop:disable Style/RescueModifier

  def tls_ctx
    @tls_ctx ||= begin
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=fake")
      cert.public_key = key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      cert.sign(key, "SHA256")
      OpenSSL::SSL::SSLContext.new.tap { |c| c.cert = cert; c.key = key } # rubocop:disable Style/Semicolon
    end
  end

  # Servidor local: cada conexão numa thread com `serve.(socket)`.
  def server(tls: false, &serve)
    tcp = TCPServer.new("127.0.0.1", 0)
    servers << tcp
    listener = tls ? OpenSSL::SSL::SSLServer.new(tcp, tls_ctx) : tcp
    Thread.new do
      loop do
        sock = listener.accept
        Thread.new(sock) do |s|
          serve.call(s)
        rescue EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError
          nil
        ensure
          s.close rescue nil # rubocop:disable Style/RescueModifier
        end
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        break if tcp.closed?
      end
    end
    tcp.addr[1]
  end

  # WebSocket falso: on_open(reply) e handler(mensagem, reply).
  def ws_server(tls: false, on_open: nil, &handler)
    server(tls: tls) do |s|
      d = WebSocket::Driver.server(s)
      reply = ->(o) { d.text(o.to_json) }
      d.on(:connect) { d.start }
      d.on(:open) { on_open&.call(reply) }
      d.on(:message) { |e| handler.call(JSON.parse(e.data), reply) }
      loop { d.parse(s.readpartial(4096)) }
    end
  end

  def add(plugin, port, **form)
    o = plugin.setup(site, ActionController::Parameters.new(host: "127.0.0.1", port: port, **form))
    expect(o.alert).to be_nil
    Integrations.adopt!(o.integration, o.integration.found.to_h { |e| [ e["id"], "" ] })
    device = site.devices.find_by!(driver: plugin.driver)
    [ o.integration, device, device.points.find_by!(capability: "media") ]
  end

  def command(point, cmd, value = nil) = Drivers::REGISTRY.fetch(point.device.driver).constantize.new.execute(point.reload, cmd, value)

  describe "Chromecast (CastV2)" do
    let(:log) { [] }
    let(:port) do
      media_state = { "playerState" => "PLAYING" }
      server(tls: true) do |c|
        pinged = false
        loop do
          len = c.read(4) or break
          f = Proto.decode(c.read(len.unpack1("N")))
          dest = Proto.string(f[3].first)
          data = JSON.parse(Proto.string(f[6].first))
          log << [ dest, data["type"], data.except("requestId", "type") ]
          send = lambda do |payload|
            m = Proto.encode([ [ 1, :enum, 0 ], [ 2, :string, dest ], [ 3, :string, "sender-0" ], [ 4, :string, "ns" ], [ 5, :enum, 0 ], [ 6, :string, payload.to_json ] ])
            c.write([ m.bytesize ].pack("N") + m)
          end
          unless pinged
            send.call("type" => "PING")
            pinged = true
          end
          next if %w[CONNECT PONG].include?(data["type"])

          media_state["playerState"] = "PAUSED" if data["type"] == "PAUSE"
          receiver = { "volume" => { "level" => 0.25, "muted" => false },
                       "applications" => [ { "appId" => "CC1AD845", "displayName" => "Spotify", "transportId" => "t-1", "sessionId" => "s-1" } ] }
          payload = if dest == "receiver-0"
            { "type" => "RECEIVER_STATUS", "status" => receiver }
          else
            { "type" => "MEDIA_STATUS", "status" => [ media_state.merge("mediaSessionId" => 7, "media" => { "metadata" => { "title" => "Música", "artist" => "Banda" } }) ] }
          end
          send.call(payload.merge("requestId" => data["requestId"]))
        end
      end
    end

    it "lê o que toca, comanda volume, pausa e tocar endereço, e responde PING" do
      integration, device, point = add(Integrations::CastPlugin, port)
      expect(integration.settings).to include("host" => "127.0.0.1")
      expect(device).to have_attributes(manufacturer: "Google", poll_s: 60)
      expect(point.address["supports"]).to eq(Drivers::Cast::SUPPORTS)
      expect(point.reload.value).to eq("state" => "playing", "app" => "Spotify", "volume" => 25, "muted" => false, "title" => "Música", "artist" => "Banda")
      expect(log.map { |l| l[1] }).to include("PONG")

      command(point, "volume", 40)
      expect(log).to include([ "receiver-0", "SET_VOLUME", { "volume" => { "level" => 0.4 } } ])
      command(point, "pause")
      expect(log).to include([ "t-1", "PAUSE", { "mediaSessionId" => 7 } ])
      expect(point.reload.value["state"]).to eq("paused")
      command(point, "play_media", "http://192.168.0.5/som.mp3")
      expect(log).to include([ "receiver-0", "LAUNCH", { "appId" => "CC1AD845" } ])
      expect(log.find { |l| l[1] == "LOAD" }[2]).to include("media" => { "contentId" => "http://192.168.0.5/som.mp3", "contentType" => "audio/mpeg", "streamType" => "BUFFERED" })
      command(point, "off")
      expect(log).to include([ "receiver-0", "STOP", { "sessionId" => "s-1" } ])
    end

    it "sem resposta vira aviso no assistente, não exceção" do
      dead = TCPServer.new("127.0.0.1", 0).tap { |s| servers << s }.addr[1]
      servers.last.close
      o = Integrations::CastPlugin.setup(site, ActionController::Parameters.new(host: "127.0.0.1", port: dead))
      expect(o.alert).to match(/Não deu para ler/)
    end
  end

  describe "LG webOS (SSAP)" do
    let(:log) { [] }
    let(:port) do
      ws_server do |m, reply|
        log << [ m["type"], m["uri"], m["payload"] ]
        if m["type"] == "register"
          reply.call("type" => "response", "id" => m["id"], "payload" => { "pairingType" => "PROMPT" }) unless m.dig("payload", "client-key")
          reply.call("type" => "registered", "id" => m["id"], "payload" => { "client-key" => "CHAVE-TV" })
        else
          payload = { "ssap://audio/getVolume" => { "volumeStatus" => { "volume" => 12, "muteStatus" => false } },
                      "ssap://com.webos.applicationManager/getForegroundAppInfo" => { "appId" => "netflix" },
                      "ssap://system/getSystemInfo" => { "modelName" => "OLED55C1" },
                      "ssap://com.webos.service.connectionmanager/getinfo" => { "wiredInfo" => { "macAddress" => "aa:bb:cc:dd:ee:ff" } } }.fetch(m["uri"], {})
          reply.call("type" => "response", "id" => m["id"], "payload" => payload.merge("returnValue" => true))
        end
      end
    end

    it "pareia, guarda a chave cifrada, lê e comanda; ligar é Wake-on-LAN" do
      integration, device, point = add(Integrations::WebosPlugin, port)
      expect(integration.reload.secrets["client_key"]).to eq("CHAVE-TV")
      expect(device).to have_attributes(external_id: "webos:aa:bb:cc:dd:ee:ff", model: "OLED55C1")
      expect(point.address["supports"]).to include("on", "volume", "play_media")
      expect(point.reload.value).to eq("state" => "on", "app" => "netflix", "volume" => 12, "muted" => false)

      command(point, "volume", 30)
      command(point, "mute", true)
      command(point, "play_media", "https://youtu.be/x")
      expect(log).to include([ "request", "ssap://audio/setVolume", { "volume" => 30 } ], [ "request", "ssap://audio/setMute", { "mute" => true } ],
                             [ "request", "ssap://system.launcher/open", { "target" => "https://youtu.be/x" } ])
      expect(log.select { |l| l[0] == "register" }.last[2]["client-key"]).to eq("CHAVE-TV")

      sent = []
      allow_any_instance_of(UDPSocket).to receive(:send) { |_s, data, _f, host, port| sent << [ data, host, port ] } # rubocop:disable RSpec/AnyInstance
      Drivers::Webos.run(device, "on", nil)
      expect(sent.first[1..]).to eq([ "255.255.255.255", 9 ])
      expect(sent.first[0]).to eq(("\xFF" * 6).b + ([ "aabbccddeeff" ].pack("H*") * 16))
    end

    it "TV desligada (sem resposta) fica Desligada, não Sem sinal" do
      _, device, point = add(Integrations::WebosPlugin, port)
      device.update!(address: device.address.merge("port" => 1))
      expect(Polling.poll_device(device.id)).to be(true)
      expect(point.reload).to have_attributes(value: { "state" => "off" }, quality: "good")
    end

    it "pareamento não aceito a tempo vira aviso" do
      silent = ws_server { |_m, _r| nil }
      stub_const("Integrations::WebosPlugin::PAIR_S", 0.3)
      o = Integrations::WebosPlugin.setup(site, ActionController::Parameters.new(host: "127.0.0.1", port: silent))
      expect(o.alert).to match(/Aceite o pedido na tela da TV/)
    end
  end

  describe "Samsung Tizen" do
    let(:keys) { [] }
    let(:port) do
      ws_server(tls: true, on_open: ->(reply) { reply.call("event" => "ms.channel.connect", "data" => { "token" => "TOKEN-1" }) }) { |m, _| keys << m.dig("params", "DataOfCmd") }
    end

    before do
      stub_request(:get, "http://127.0.0.1:8001/api/v2/")
        .to_return(body: { "device" => { "PowerState" => "on", "id" => "uuid:tv-1", "modelName" => "QN55Q60", "wifiMac" => "11:22:33:44:55:66" } }.to_json)
    end

    it "pareia (token cifrado), lê o estado e manda teclas; sem volume exato" do
      integration, device, point = add(Integrations::TizenPlugin, port)
      expect(integration.reload.secrets["token"]).to eq("TOKEN-1")
      expect(device).to have_attributes(external_id: "tizen:uuid:tv-1", model: "QN55Q60")
      expect(Points::Command.commands_for(point)).not_to include("volume", "play_media")
      expect(Points::Command.commands_for(point)).to include("on", "volume_up", "mute")
      expect(point.reload.value).to eq("state" => "on")

      command(point, "volume_up")
      command(point, "pause")
      expect(keys).to eq(%w[KEY_VOLUP KEY_PAUSE])
      expect { Points::Command.call(point, "volume", 10, source: "web") }.to raise_error(Points::Command::Error)
    end

    it "TV recusou o acesso vira aviso" do
      refused = ws_server(tls: true, on_open: ->(reply) { reply.call("event" => "ms.channel.unauthorized") }) { |_m, _r| nil }
      o = Integrations::TizenPlugin.setup(site, ActionController::Parameters.new(host: "127.0.0.1", port: refused))
      expect(o.alert).to match(/recusou o acesso/)
    end
  end

  describe "Android TV por ADB" do
    let(:shell) { [] }
    let(:trusted) { [] }

    def adb_port
      server do |s|
        read = lambda do
          code, a0, a1, len = (s.read(24) or raise EOFError).unpack("V4")
          [ Drivers::Adb::Client::CMD.key(code), a0, a1, len.zero? ? "".b : s.read(len) ]
        end
        put = lambda do |cmd, a0, a1, data|
          code = Drivers::Adb::Client::CMD.fetch(cmd)
          s.write([ code, a0, a1, data.bytesize, data.bytes.sum, code ^ 0xFFFF_FFFF ].pack("V6") + data.b)
        end
        token = SecureRandom.bytes(20)
        loop do
          cmd, a0, _, data = read.call
          case cmd
          when :cnxn then put.call(:auth, 1, 0, token)
          when :auth
            if a0 == 2 && trusted.any? { |k| k.verify_raw("sha1", data, token) }
              put.call(:cnxn, 0x01000000, 4096, "device::ro.product.name=tv;")
            elsif a0 == 2
              put.call(:auth, 1, 0, token)
            else
              raw = Base64.decode64(data.split(" ").first)
              words, n0inv = raw.unpack("VV")
              n = raw.byteslice(8, words * 4).reverse.unpack1("H*").to_i(16)
              e = raw.byteslice(8 + (words * 8), 4).unpack1("V")
              expect((n0inv * n) % (1 << 32)).to eq((1 << 32) - 1)
              expect(raw.byteslice(8 + (words * 4), words * 4).reverse.unpack1("H*").to_i(16)).to eq((1 << (words * 64)) % n)
              trusted << OpenSSL::PKey::RSA.new(OpenSSL::ASN1::Sequence([ OpenSSL::ASN1::Integer(n), OpenSSL::ASN1::Integer(e) ]).to_der)
              put.call(:cnxn, 0x01000000, 4096, "device::")
            end
          when :open
            line = data.delete_prefix("shell:").delete_suffix("\0")
            shell << line
            out = if line.start_with?("getprop") then "SER123\nChromecast HD\nGoogle\n"
            elsif line == Drivers::Adb::STATE then "  mWakefulness=Awake\n  mCurrentFocus=Window{1a2b u0 com.netflix.ninja/com.netflix.ninja.MainActivity}\n"
            else ""
            end
            put.call(:okay, 99, a0, "")
            put.call(:wrte, 99, a0, out) unless out.empty?
            read.call unless out.empty? # OKAY do cliente
            put.call(:clse, 99, a0, "")
          end
        end
      end
    end

    it "pareia com a chave própria (formato do Android), lê e manda teclas e endereço" do
      port = adb_port
      integration, device, point = add(Integrations::AdbPlugin, port)
      expect(trusted.size).to eq(1)
      expect(integration.reload.secrets["adb_key"]).to start_with("-----BEGIN")
      expect(device).to have_attributes(external_id: "adb:SER123", model: "Chromecast HD", manufacturer: "Google")
      expect(point.reload.value).to eq("state" => "on", "app" => "com.netflix.ninja")

      command(point, "volume_down")
      command(point, "play_media", "https://site/x?a=1&b=2")
      expect(shell).to include("input keyevent 25", "am start -a android.intent.action.VIEW -d https://site/x\\?a\\=1\\&b\\=2")
    end

    it "estado desligado e app só com a tela acesa" do
      expect(Drivers::Adb.state("mWakefulness=Asleep\nmCurrentFocus=Window{x u0 com.app/Act}")).to eq("state" => "off")
    end
  end
end
