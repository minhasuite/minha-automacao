require "rails_helper"
require "socket"

# catalogo (grupo 9): integrações do catálogo como SchemaPlugin (campos →
# formulário, o plugin é o driver). Respostas gravadas (WebMock) e aparelhos
# de mentira em 127.0.0.1 (TCP/UDP); nada de rede real nem conta real.
RSpec.describe "Catálogo de integrações (grupo 9)" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:servers) { [] }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def json(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  def form(h) = ActionController::Parameters.new(h)

  def add(plugin, h)
    o = plugin.setup(site, form(h))
    expect(o.alert).to be_nil
    Integrations.adopt!(o.integration, o.integration.found.to_h { |e| [ e["id"], "" ] })
    o.integration
  end

  def run(point, command, value = nil) = ExecuteCommandJob.perform_now(Points::Command.call(point, command, value, source: "web").id)
  def pts(integration) = integration.devices.first.points.reload.index_by { |p| p.address["field"] }

  # Servidor TCP de mentira: cada conexão vai para o bloco (socket).
  def tcp_server
    server = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      loop do
        c = server.accept
        Thread.new(c) do |s|
          yield s
        rescue IOError, SystemCallError
          nil
        ensure
          s.close
        end
      end
    rescue IOError
      nil
    end
    servers << server
    server.addr[1]
  end


  after { servers.each(&:close) }

  describe "SchemaPlugin (núcleo aberto)" do
    let(:fake) do
      Class.new(Integrations::SchemaPlugin) do
        describe key: "teste_schema", title: "Teste Schema", icon: "bolt", description: "Teste"
        texts en: { title: "Schema test", description: "Test", fields: { area: "Area" } }, es: { title: "Prueba", description: "Prueba", fields: { area: "Área" } },
              "pt-BR" => { fields: { area: "Área" } }
        field :host, required: true
        field :area, :select, options: %w[a b], default: "a"
        field :token, secret: true
        def self.state = (@state ||= { "on" => false, "temperature" => 21.5 })
        def self.entries(i) = [ entry(id: "t:#{conf(i, :host)}", name: "Teste Aparelho", address: { "area" => conf(i, :area) },
                                      points: [ point("on", "onoff", name: "Teste Liga"), point("temperature", unit: "°C") ]) ]
        def self.read(_device) = state.dup
        def self.write(point, value) = state[point.address["field"]] = value
      end
    end

    before do
      stub_const("Integrations::FakeSchemaPlugin", fake)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS + [ "FakeSchemaPlugin" ])
    end

    it "valida o obrigatório, guarda o segredo cifrado, é o driver dos aparelhos e lê e comanda sem linha no núcleo" do
      expect(fake.setup(site, form(token: "x")).alert).to include("Endereço")
      i = add(fake, host: "10.0.0.9", token: "segredo")
      expect(i.settings).to include("host" => "10.0.0.9", "account" => "10.0.0.9")
      expect(i.settings.to_json).not_to include("segredo")
      expect(fake.conf(i, :token)).to eq("segredo")
      expect(fake.conf(i, :area)).to eq("a")
      device = i.devices.first
      expect([ Drivers.supported?(device), Polling.supported?(device) ]).to eq([ true, true ])
      expect(pts(i)["temperature"].value).to eq(21.5)
      expect(pts(i)["temperature"].name).to eq("Temperatura")
      run(pts(i)["on"], "on")
      expect(pts(i)["on"].value).to be(true)
      expect(Polling.poll_device(device.id)).to be(true)
    end

    it "o formulário sai dos campos (web e app pela mesma partial)" do
      expect(ApplicationController.helpers.integration_form_partial(fake)).to eq("web/integrations/forms/schema")
      expect(ApplicationController.helpers.integration_form_partial(Integrations::WledPlugin)).to eq("web/integrations/forms/wled")
      I18n.with_locale(:en) { expect([ fake.field_label(:area), fake.field_label(:host), fake.option_label(:area, "b") ]).to eq([ "Area", "Address (IP or name)", "b" ]) }
    end
  end

  describe "rede e casa (D10)" do
    it "WiZ: lê e comanda pelo UDP local" do
      sock = UDPSocket.new
      sock.bind("127.0.0.1", 0)
      stub_const("Integrations::WizPlugin::PORT", sock.addr[1])
      pilot = { "state" => true, "dimming" => 40, "r" => 255, "g" => 0, "b" => 0 }
      sent = []
      Thread.new do
        loop do
          msg, from = sock.recvfrom(2048)
          req = JSON.parse(msg)
          sent << req
          pilot.merge!(req["params"].transform_keys(&:to_s)) if req["method"] == "setPilot"
          result = req["method"] == "getSystemConfig" ? { "mac" => "a8bb50aabbcc", "moduleName" => "ESP01_SHRGB_03" } : pilot
          sock.send({ result: result }.to_json, 0, from[3], from[1])
        end
      rescue IOError
        nil
      end
      i = add(Integrations::WizPlugin, host: "127.0.0.1")
      p = pts(i)
      expect([ p["state"].value, p["dimming"].value, p["color"].value["h"] ]).to eq([ true, 40, 0.0 ])
      run(p["dimming"], "set", 80)
      expect(sent.find { |r| r["method"] == "setPilot" }).to eq("method" => "setPilot", "params" => { "state" => true, "dimming" => 80 })
      expect(pts(i)["dimming"].value).to eq(80)
    ensure
      sock&.close
    end

    it "TP-Link Kasa: filtro de linha com uma tomada por ponto e energia (XOR na 9999)" do
      info = { "alias" => "Teste Filtro", "model" => "HS300", "mac" => "50:C7:BF:00:00:01", "feature" => "TIM:ENE",
               "children" => [ { "id" => "c1", "alias" => "Teste TV", "state" => 1 }, { "id" => "c2", "alias" => "Teste Som", "state" => 0 } ] }
      reqs = []
      port = tcp_server do |s|
        len = s.read(4).unpack1("N")
        req = JSON.parse(Integrations::TplinkPlugin.xor(s.read(len), decrypt: true))
        reqs << req
        if (set = req.dig("system", "set_relay_state"))
          info["children"].find { |c| c["id"] == req.dig("context", "child_ids", 0) }["state"] = set["state"]
        end
        body = Integrations::TplinkPlugin.xor({ system: { get_sysinfo: info }, emeter: { get_realtime: { power_mw: 12_300, total_wh: 4500 } } }.to_json)
        s.write([ body.bytesize ].pack("N") + body)
      end
      stub_const("Integrations::TplinkPlugin::KASA_PORT", port)
      i = add(Integrations::TplinkPlugin, host: "127.0.0.1", protocol: "kasa")
      p = pts(i)
      expect(p.keys).to contain_exactly("relay:c1", "relay:c2", "power", "energy")
      expect([ p["relay:c1"].name, p["relay:c1"].value, p["relay:c2"].value, p["power"].value, p["energy"].value ]).to eq([ "Teste TV", true, false, 12.3, 4.5 ])
      run(p["relay:c2"], "on")
      expect(reqs.find { |r| r["context"] }).to eq("context" => { "child_ids" => [ "c2" ] }, "system" => { "set_relay_state" => { "state" => 1 } })
      expect(pts(i)["relay:c2"].value).to be(true)
    end

    it "TP-Link Tapo: KLAP v2 confere o hash da conta e cifra cada pedido" do
      auth = Integrations::TplinkPlugin.auth_hash("teste@exemplo.com", "senha-teste")
      sha = ->(*a) { OpenSSL::Digest::SHA256.digest(a.join) }
      state = { "device_on" => false, "nickname" => Base64.strict_encode64("Teste Tomada"), "model" => "P110", "mac" => "AA-BB" }
      seeds = {}
      stub_request(:post, "http://10.9.9.9/app/handshake1").to_return do |req|
        seeds[:local] = req.body.b
        seeds[:remote] = "R" * 16
        { status: 200, body: seeds[:remote] + sha.(seeds[:local], seeds[:remote], auth), headers: { "Set-Cookie" => "TP_SESSIONID=abc;TIMEOUT=86400" } }
      end
      stub_request(:post, "http://10.9.9.9/app/handshake2").to_return(status: 200, body: "")
      stub_request(:post, %r{http://10\.9\.9\.9/app/request\?seq=}).to_return do |req|
        l, r = seeds.values_at(:local, :remote)
        key = sha.("lsk", l, r, auth)[0, 16]
        iv = sha.("iv", l, r, auth)[0, 12]
        seq = req.uri.query[/seq=(-?\d+)/, 1].to_i
        expect(req.headers["Cookie"]).to eq("TP_SESSIONID=abc")
        d = OpenSSL::Cipher.new("aes-128-cbc").decrypt.tap { |c| c.key = key; c.iv = iv + [ seq ].pack("l>") }
        body = JSON.parse(d.update(req.body.b[32..]) + d.final)
        state.merge!(body["params"]) if body["method"] == "set_device_info"
        result = body["method"] == "get_energy_usage" ? { "current_power" => 5500, "month_energy" => 1200 } : state
        e = OpenSSL::Cipher.new("aes-128-cbc").encrypt.tap { |c| c.key = key; c.iv = iv + [ seq ].pack("l>") }
        { status: 200, body: ("\0" * 32) + e.update({ error_code: 0, result: result }.to_json) + e.final }
      end
      i = add(Integrations::TplinkPlugin, host: "10.9.9.9", protocol: "tapo", username: "teste@exemplo.com", password: "senha-teste")
      expect(i.devices.first.name).to eq("Teste Tomada")
      expect(pts(i)["power"].value).to eq(5.5)
      run(pts(i)["device_on"], "on")
      expect(state["device_on"]).to be(true)

      o = Integrations::TplinkPlugin.setup(site, form(host: "10.9.9.9", protocol: "tapo", username: "teste@exemplo.com", password: "errada"))
      expect(o.alert).to include("recusou")
    end

    it "AdGuard Home: proteção e filtros como chaves, consultas e bloqueios como medida" do
      base = "http://192.0.2.5:3000/control"
      stub_request(:get, "#{base}/status").with(basic_auth: %w[admin teste]).to_return(json("protection_enabled" => true, "version" => "v0.107.0"))
      stub_request(:get, "#{base}/stats").to_return(json("num_dns_queries" => 200, "num_blocked_filtering" => 50, "avg_processing_time" => 0.0123))
      %w[filtering safebrowsing parental safesearch].each { |s| stub_request(:get, "#{base}/#{s}/status").to_return(json("enabled" => s == "filtering", "interval" => 24)) }
      toggle = stub_request(:post, "#{base}/parental/enable").to_return(json({}))
      prot = stub_request(:post, "#{base}/protection").with(body: { enabled: false }.to_json).to_return(json({}))
      i = add(Integrations::AdguardPlugin, host: "192.0.2.5", username: "admin", password: "teste")
      p = pts(i)
      expect([ p["protection"].value, p["parental"].value, p["blocked_ratio"].value, p["avg_ms"].value ]).to eq([ true, false, 25.0, 12.3 ])
      run(p["parental"], "on")
      run(p["protection"], "off")
      expect([ toggle, prot ]).to all(have_been_requested)
    end

    it "NUT: cada nobreak do servidor vira aparelho com bateria, autonomia e estado" do
      status = +"OL"
      port = tcp_server do |s|
        while (line = s.gets)
          case line.chomp
          when /\AUSERNAME|\APASSWORD/ then s.write("OK\n")
          when "LIST UPS" then s.write("BEGIN LIST UPS\nUPS teste \"Teste Nobreak\"\nEND LIST UPS\n")
          when "LIST VAR teste"
            s.write("BEGIN LIST VAR teste\nVAR teste battery.charge \"87\"\nVAR teste battery.runtime \"1800\"\nVAR teste input.voltage \"127.0\"\n" \
                    "VAR teste ups.load \"23\"\nVAR teste ups.status \"#{status}\"\nVAR teste device.mfr \"APC\"\nEND LIST VAR teste\n")
          end
        end
      end
      i = add(Integrations::NutPlugin, host: "127.0.0.1", port: port, username: "upsmon", password: "teste")
      p = pts(i)
      expect([ i.devices.first.name, p["battery"].value, p["runtime"].value, p["input_voltage"].value, p["on_battery"].value ]).to eq([ "Teste Nobreak", 87.0, 30.0, 127.0, false ])
      expect(p.keys).not_to include("output_voltage")
      status.replace("OB LB")
      Integrations::NutPlugin.poll(i.devices.first)
      expect([ pts(i)["on_battery"].value, pts(i)["low_battery"].value ]).to eq([ true, true ])
    end

    it "Fully Kiosk: tela, brilho e botões pela API do app" do
      info = { "deviceID" => "abc", "deviceModel" => "Teste Tablet", "deviceManufacturer" => "Lenovo", "screenOn" => true, "screenBrightness" => 120,
               "batteryLevel" => 81, "currentPage" => "http://casa.local/painel" }
      stub_request(:get, %r{http://192\.0\.2\.7:2323/\?.*cmd=deviceInfo}).to_return(json(info))
      off = stub_request(:get, %r{cmd=screenOff.*password=teste}).to_return(json("status" => "OK"))
      reload = stub_request(:get, /cmd=loadStartURL/).to_return(json("status" => "OK"))
      i = add(Integrations::FullyKioskPlugin, host: "192.0.2.7", password: "teste")
      p = pts(i)
      expect([ p["screen"].value, p["brightness"].value, p["battery"].value, p["page"].value ]).to eq([ true, 120, 81, "http://casa.local/painel" ])
      run(p["screen"], "off")
      run(p["reload"], "press")
      expect([ off, reload ]).to all(have_been_requested)
      stub_request(:get, /cmd=deviceInfo/).to_return(json("status" => "Error", "statustext" => "Please enter the correct password"))
      o = Integrations::FullyKioskPlugin.setup(site, form(host: "192.0.2.7", password: "x"))
      expect(o.alert).to include("password")
    end

    it "HomeWizard: P1 com energia e gás, tomada liga/desliga" do
      stub_request(:get, "http://192.0.2.8/api").to_return(json("product_type" => "HWE-SKT", "product_name" => "Teste Tomada", "serial" => "abc", "api_version" => "v1"))
      stub_request(:get, "http://192.0.2.8/api/v1/data").to_return(json("active_power_w" => 120.5, "total_power_import_kwh" => 33.2, "wifi_strength" => 80))
      stub_request(:get, "http://192.0.2.8/api/v1/state").to_return(json("power_on" => true))
      put = stub_request(:put, "http://192.0.2.8/api/v1/state").with(body: { power_on: false }.to_json).to_return(json("power_on" => false))
      i = add(Integrations::HomewizardPlugin, host: "192.0.2.8")
      p = pts(i)
      expect(p.keys).to contain_exactly("switch", "power", "import")
      expect([ p["switch"].value, p["power"].value, p["import"].value, p["import"].state_class ]).to eq([ true, 120.5, 33.2, "total_increasing" ])
      run(p["switch"], "off")
      expect(put).to have_been_requested
    end

    it "Synology DSM: login, CPU, memória e volumes, e logout" do
      stub_request(:get, %r{192\.0\.2\.9:5001/webapi/auth\.cgi\?.*method=login}).to_return(json("success" => true, "data" => { "sid" => "s1" }))
      logout = stub_request(:get, /method=logout/).to_return(json("success" => true))
      stub_request(:get, /api=SYNO\.Core\.System&/).to_return(json("data" => { "model" => "DS920+", "serial" => "X1", "sys_temp" => 41, "up_time" => "50:30:00" }))
      stub_request(:get, /api=SYNO\.Core\.System\.Utilization/).to_return(json("data" => { "cpu" => { "user_load" => 7, "system_load" => 3 }, "memory" => { "real_usage" => 35 } }))
      vols = [ { "id" => "volume_1", "display_name" => "Volume 1", "status" => "normal", "size" => { "total" => "1000", "used" => "250" } } ]
      stub_request(:get, /api=SYNO\.Storage\.CGI\.Storage/).to_return(json("data" => { "volumes" => vols }))
      i = add(Integrations::SynologyDsmPlugin, host: "192.0.2.9", username: "teste", password: "teste")
      p = pts(i)
      expect([ p["cpu"].value, p["memory"].value, p["temperature"].value, p["uptime"].value, p["used:volume_1"].value, p["bad:volume_1"].value ])
        .to eq([ 10, 35, 41, 50.5, 25.0, false ])
      expect(p["used:volume_1"].name).to eq("Volume 1 usado")
      expect(logout).to have_been_requested.at_least_once
      stub_request(:get, /method=login/).to_return(json("success" => false, "error" => { "code" => 400 }))
      expect(Integrations::SynologyDsmPlugin.setup(site, form(host: "192.0.2.9", username: "x", password: "y")).alert).to include("400")
    end

    it "FRITZ!Box: login PBKDF2, tomada com consumo e termostato" do
      challenge = "2$10$5a1711$10$5a1722"
      stub_request(:get, "http://fritz.box/login_sid.lua?version=2")
        .to_return(status: 200, body: "<SessionInfo><SID>0000000000000000</SID><Challenge>#{challenge}</Challenge></SessionInfo>")
      good = Integrations::FritzboxPlugin.answer(challenge, "teste")
      stub_request(:get, /login_sid\.lua\?.*response=/).to_return do |req|
        sid = Rack::Utils.parse_query(req.uri.query)["response"] == good ? "abcdef0123456789" : "0000000000000000"
        { status: 200, body: "<SessionInfo><SID>#{sid}</SID></SessionInfo>" }
      end
      xml = <<~XML
        <devicelist><device identifier="11657 0240192" productname="FRITZ!DECT 200"><present>1</present><name>Teste Tomada</name>
        <switch><state>1</state></switch><powermeter><power>23500</power><energy>1500</energy><voltage>230000</voltage></powermeter>
        <temperature><celsius>215</celsius><offset>0</offset></temperature></device>
        <device identifier="09995 0000001" productname="FRITZ!DECT 301"><present>1</present><name>Teste Termostato</name>
        <temperature><celsius>200</celsius><offset>5</offset></temperature><hkr><tist>40</tist><tsoll>42</tsoll></hkr><battery>80</battery></device></devicelist>
      XML
      stub_request(:get, /getdevicelistinfos/).to_return(status: 200, body: xml)
      set = stub_request(:get, /switchcmd=sethkrtsoll/).with(query: hash_including("param" => "44")).to_return(status: 200, body: "44")
      i = add(Integrations::FritzboxPlugin, username: "teste", password: "teste")
      by = i.devices.index_by(&:name)
      pp = by["Teste Tomada"].points.index_by { |x| x.address["field"] }
      hp = by["Teste Termostato"].points.index_by { |x| x.address["field"] }
      expect([ pp["switch"].value, pp["power"].value, pp["energy"].value, pp["temperature"].value ]).to eq([ true, 23.5, 1.5, 21.5 ])
      expect([ hp["temperature"].value, hp["setpoint"].value, hp["battery"].value ]).to eq([ 20.5, 21.0, 80 ])
      run(hp["setpoint"], "set", 22)
      expect(set).to have_been_requested
      expect(Integrations::FritzboxPlugin.setup(site, form(username: "teste", password: "errada")).alert).to include("recusou")
    end

    it "Denon AVR: zona principal como player (volume em dB, mudo, entrada)" do
      stub_request(:get, "http://192.0.2.10:80/goform/formMainZone_MainZoneXmlStatusLite.xml")
        .to_return(status: 200, body: "<item><Power><value>ON</value></Power><InputFuncSelect><value>TV</value></InputFuncSelect>" \
                                      "<MasterVolume><value>-40.0</value></MasterVolume><Mute><value>off</value></Mute></item>")
      stub_request(:get, "http://192.0.2.10:80/goform/formMainZone_MainZoneXml.xml").to_return(status: 200, body: "<item><FriendlyName><value>Teste Sala</value></FriendlyName></item>")
      sent = stub_request(:get, %r{/goform/formiPhoneAppDirect\.xml\?}).to_return(status: 200, body: "")
      i = add(Integrations::DenonavrPlugin, host: "192.0.2.10")
      media = pts(i)["media"]
      expect(i.devices.first.name).to eq("Teste Sala")
      expect(media.value).to eq("state" => "on", "volume" => 50, "muted" => false, "source" => "TV")
      run(media, "volume", 50)
      run(media, "play_media", "Blu-ray")
      run(media, "off")
      expect(a_request(:get, "http://192.0.2.10:80/goform/formiPhoneAppDirect.xml?MV40")).to have_been_made
      expect(a_request(:get, "http://192.0.2.10:80/goform/formiPhoneAppDirect.xml?SIBLU-RAY")).to have_been_made
      expect(sent).to have_been_requested.times(3)
    end

    it "HEOS: cada player vira aparelho; estado, música e comandos pela CLI (TCP 1255)" do
      cmds = []
      replies = { "player/get_play_state" => "pid=7&state=play", "player/get_volume" => "pid=7&level=25", "player/get_mute" => "pid=7&state=off" }
      payloads = { "player/get_players" => [ { "name" => "Teste Cozinha", "pid" => 7, "model" => "HEOS 1" } ],
                   "player/get_now_playing_media" => { "song" => "Teste Música", "artist" => "Teste Banda" } }
      port = tcp_server do |s|
        while (line = s.gets("\r\n"))
          cmd = line.strip.delete_prefix("heos://")
          cmds << cmd
          path = cmd.split("?").first
          reply = { "heos" => { "command" => path, "result" => "success", "message" => replies[path] || cmd.split("?", 2)[1].to_s }, "payload" => payloads[path] }.compact
          s.write("#{reply.to_json}\r\n")
        end
      end
      stub_const("Integrations::HeosPlugin::PORT", port)
      i = add(Integrations::HeosPlugin, host: "127.0.0.1")
      media = pts(i)["media"]
      expect(media.value).to eq("state" => "playing", "volume" => 25, "muted" => false, "title" => "Teste Música", "artist" => "Teste Banda")
      run(media, "pause")
      run(media, "play_media", "http://radio.local/stream.mp3")
      expect(cmds).to include("player/set_play_state?pid=7&state=pause", "browse/play_stream?pid=7&url=http://radio.local/stream.mp3")
    end

    it "Sony Bravia: JSON-RPC com a PSK; desligada não lê o resto" do
      power = +"active"
      rpc = lambda do |svc, method, result|
        stub_request(:post, "http://192.0.2.11/sony/#{svc}").with(body: hash_including("method" => method), headers: { "X-Auth-PSK" => "0000" })
                                                          .to_return(json("result" => result, "id" => 1))
      end
      rpc.call("system", "getSystemInformation", [ { "name" => "Teste TV", "model" => "KD-55X80J", "macAddr" => "aa:bb" } ])
      stub_request(:post, "http://192.0.2.11/sony/system").with(body: hash_including("method" => "getPowerStatus")).to_return { json("result" => [ { "status" => power } ]) }
      rpc.call("audio", "getVolumeInformation", [ [ { "target" => "speaker", "volume" => 18, "mute" => false } ] ])
      rpc.call("avContent", "getPlayingContentInfo", [ { "title" => "HDMI 1", "uri" => "extInput:hdmi?port=1" } ])
      vol = rpc.call("audio", "setAudioVolume", [])
      i = add(Integrations::BraviatvPlugin, host: "192.0.2.11", psk: "0000")
      media = pts(i)["media"]
      expect(media.value).to eq("state" => "on", "volume" => 18, "muted" => false, "source" => "HDMI 1", "app" => "extInput:hdmi?port=1")
      run(media, "volume", 30)
      expect(vol).to have_been_requested
      power.replace("standby")
      Integrations::BraviatvPlugin.poll(i.devices.first)
      expect(pts(i)["media"].value).to eq("state" => "off")
    end
  end

  describe "dados (D13)" do
    before { site.update!(latitude: -23.55, longitude: -46.63, timezone: "America/Sao_Paulo") }

    it "Met.no e OpenWeatherMap são provedores do Clima (formato comum)" do
      expect(Weather.choices.keys).to include("open_meteo", "met_no", "openweathermap")
      met = { "properties" => { "timeseries" => [
        { "time" => "2026-11-03T15:00:00Z", "data" => { "instant" => { "details" => { "air_temperature" => 27.1, "relative_humidity" => 60, "wind_speed" => 2.5 } },
                                                         "next_1_hours" => { "summary" => { "symbol_code" => "rainshowers_day" }, "details" => { "precipitation_amount" => 1.2 } } } },
        { "time" => "2026-11-03T16:00:00Z", "data" => { "instant" => { "details" => { "air_temperature" => 29.0 } },
                                                         "next_1_hours" => { "summary" => { "symbol_code" => "heavyrainandthunder" } } } }
      ] } }
      stub_request(:get, %r{api\.met\.no/weatherapi/locationforecast/2\.0/compact\?lat=-23\.55&lon=-46\.63}).with(headers: { "User-Agent" => /MinhaAutomacao/ })
                                                                                                       .to_return(json(met))
      d = Weather::Providers::MetNo.fetch(lat: -23.55, lon: -46.63, zone: "America/Sao_Paulo")
      expect(d["current"]).to include("condition" => "rainy", "temperature" => 27.1, "humidity" => 60, "wind_speed" => 9.0)
      expect(d["hourly"].map { |h| h["condition"] }).to eq(%w[rainy lightning-rainy])
      expect(d["daily"].first).to include("date" => "2026-11-03", "temperature_max" => 29.0, "temperature_min" => 27.1, "precipitation" => 1.2)

      now = { "weather" => [ { "id" => 800 } ], "main" => { "temp" => 25.3, "feels_like" => 26, "humidity" => 50 }, "wind" => { "speed" => 5 },
              "dt" => 100, "sys" => { "sunrise" => 50, "sunset" => 200 } }
      fc = { "list" => [ { "dt" => 1_793_000_000, "main" => { "temp" => 24, "temp_max" => 26, "temp_min" => 20 }, "weather" => [ { "id" => 502 } ], "pop" => 0.8,
                           "rain" => { "3h" => 4.5 }, "sys" => { "pod" => "d" } } ] }
      stub_request(:get, %r{api\.openweathermap\.org/data/2\.5/weather\?.*appid=chave-teste}).to_return(json(now))
      stub_request(:get, %r{api\.openweathermap\.org/data/2\.5/forecast\?}).to_return(json(fc))
      o = Weather::Providers::OpenWeatherMap.fetch(lat: -23.55, lon: -46.63, zone: "America/Sao_Paulo", api_key: "chave-teste")
      expect(o["current"]).to include("condition" => "sunny", "temperature" => 25.3, "wind_speed" => 18.0, "precipitation_probability" => 80)
      expect(o["daily"].first).to include("condition" => "pouring", "temperature_max" => 26, "temperature_min" => 20, "precipitation" => 4.5)
      stub_request(:get, /openweathermap/).to_return(status: 401, body: "{}")
      expect { Weather::Providers::OpenWeatherMap.fetch(lat: 1, lon: 1, zone: "UTC", api_key: "x") }.to raise_error(Weather::Error, /recusou/)
    end

    it "Forecast.Solar: previsão de hoje, de amanhã, a de agora e a que falta" do
      result = { "watts" => { "2026-11-03 06:00:00" => 0, "2026-11-03 12:00:00" => 3100, "2026-11-03 18:00:00" => 0 },
                 "watt_hours" => { "2026-11-03 06:00:00" => 0, "2026-11-03 12:00:00" => 9000, "2026-11-03 18:00:00" => 21_000 },
                 "watt_hours_day" => { "2026-11-03" => 21_000, "2026-11-04" => 18_500 } }
      stub_request(:get, "https://api.forecast.solar/estimate/-23.55/-46.63/20/180/5.4").to_return(json("result" => result, "message" => { "code" => 0 }))
      i = travel_to(Time.zone.parse("2026-11-03 13:30 -03:00")) { add(Integrations::ForecastSolarPlugin, kwp: "5,4") }
      p = pts(i)
      expect([ p["power_now"].value, p["energy_today"].value, p["energy_tomorrow"].value, p["energy_remaining"].value ]).to eq([ 3100, 21.0, 18.5, 12.0 ])
      expect(p["energy_today"].unit).to eq("kWh")
      site.update!(latitude: nil)
      expect(Integrations::ForecastSolarPlugin.setup(site, form(kwp: "3")).alert).to include("latitude")
    end

    it "Electricity Maps: intensidade de carbono e parte fóssil (o painel de energia lê em %)" do
      stub_request(:get, %r{electricitymap\.org/v3/carbon-intensity/latest\?lat=-23\.55&lon=-46\.63}).with(headers: { "auth-token" => "tok-teste" })
                                                                                                 .to_return(json("zone" => "BR-CS", "carbonIntensity" => 95))
      stub_request(:get, %r{electricitymap\.org/v3/power-breakdown/latest}).to_return(json("fossilFreePercentage" => 88))
      i = add(Integrations::Co2signalPlugin, token: "tok-teste")
      expect(i.devices.first.name).to eq("Electricity Maps BR-CS")
      expect([ pts(i)["intensity"].value, pts(i)["fossil"].value ]).to eq([ 95, 12.0 ])
      stub_request(:get, /carbon-intensity/).to_return(status: 401, body: { message: "Invalid token" }.to_json)
      expect(Integrations::Co2signalPlugin.setup(site, form(token: "x")).alert).to include("Invalid token")
    end

    it "Lua e estação do ano: calculadas aqui, no idioma em que nasceram e no hemisfério do local" do
      expect(Integrations::MoonPlugin.phase(Time.utc(2026, 11, 24, 15))[0]).to eq("full_moon") # lua cheia de 24/11/2026
      expect(Integrations::MoonPlugin.phase(Time.utc(2026, 11, 10, 0))[0]).to eq("new_moon")
      expect(Integrations::SeasonPlugin.starts(2026)[0].utc.to_date).to eq(Date.new(2026, 3, 20))
      expect(Integrations::SeasonPlugin.starts(2026)[3].utc.to_date).to eq(Date.new(2026, 12, 21))
      expect(Integrations::SeasonPlugin.season(Time.utc(2026, 11, 3), south: true)).to eq("spring")
      expect(Integrations::SeasonPlugin.season(Time.utc(2026, 11, 3))).to eq("autumn")
      expect(Integrations::SeasonPlugin.season(Time.utc(2026, 12, 5), south: true, type: "meteorological")).to eq("summer")

      moon = I18n.with_locale(:en) { add(Integrations::MoonPlugin, {}) }
      travel_to(Time.utc(2026, 11, 24, 15)) { Integrations::MoonPlugin.poll(moon.devices.first) }
      expect(pts(moon)["phase"].value).to eq("Full moon")
      season = add(Integrations::SeasonPlugin, type: "astronomical")
      travel_to(Time.utc(2026, 11, 3)) { Integrations::SeasonPlugin.poll(season.devices.first) }
      expect(pts(season)["season"].value).to eq("Primavera")
    end

    it "Feriados: nacionais e do estado viram agenda (ponto calendar)" do
      list = [ { "date" => "2026-11-15", "localName" => "Proclamação da República", "global" => true },
               { "date" => "2026-11-20", "localName" => "Consciência Negra", "global" => false, "counties" => [ "BR-SP" ] },
               { "date" => "2026-11-20", "localName" => "Teste Só no Rio", "global" => false, "counties" => [ "BR-RJ" ] } ]
      stub_request(:get, "https://date.nager.at/api/v3/PublicHolidays/2026/BR").to_return(json(list))
      stub_request(:get, "https://date.nager.at/api/v3/PublicHolidays/2026/ZZ").to_return(status: 404, body: "")
      i = travel_to(Time.zone.parse("2026-11-03 10:00 -03:00")) { add(Integrations::HolidayPlugin, country: "br", subdivision: "BR-SP") }
      cal = pts(i)["holidays"]
      expect(cal.capability).to eq("calendar")
      expect(cal.address["events"].pluck("summary")).to eq([ "Proclamação da República", "Consciência Negra" ])
      expect(cal.address["events"].first).to include("all_day" => true, "start" => "2026-11-15T00:00:00-03:00")
      expect(Integrations::HolidayPlugin.setup(site, form(country: "ZZ")).alert).to include("ZZ")
    end

    it "Google Tradutor: fala grátis como provedor de voz (TTS), em pedaços de 200 caracteres" do
      long = "palavra " * 40
      expect(Ai::Providers::GoogleTranslate.chunks(long).map(&:size)).to all(be <= 200)
      expect(Ai::Providers::GoogleTranslate.chunks(long).join(" ").split.size).to eq(40)
      tts = stub_request(:get, %r{translate\.google\.com/translate_tts\?.*tl=pt-BR}).to_return(status: 200, body: "MP3")
      AiAccount.create!(provider: "google_translate")
      expect(Ai.choices(:tts)).to include("google_translate")
      r = Ai::Audio.speak(tenant: tenant, text: long, provider: "google_translate")
      expect(r.data).to eq({ media_type: "audio/mpeg", data: "MP3MP3" })
      expect(tts).to have_been_requested.twice
    end
  end
end
