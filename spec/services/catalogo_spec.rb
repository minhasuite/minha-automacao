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
      view = ApplicationController.new.view_context
      expect(view.integration_form_partial(Integrations::WledPlugin)).to eq("web/integrations/forms/lan")
      expect(view.integration_form_partial(Integrations::HuePlugin)).to eq("web/integrations/forms/hue")
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

  describe "nuvem (D12)" do
    # Formulário (app do dono) → passo de login → retorno do OAuth com token gravado → adota tudo.
    def oauth_add(plugin, extra = {})
      o = plugin.setup(site, form({ client_id: "cid-teste", client_secret: "csec-teste" }.merge(extra)))
      expect(o.to).to eq(:connect)
      i = o.integration
      expect(i.settings.to_json).not_to include("csec-teste")
      url = plugin.connect_locals(i, { redirect_uri: "https://ma.exemplo/integracoes/oauth/retorno" })[:auth_url]
      expect(url).to include("client_id=cid-teste", "redirect_uri=https%3A%2F%2Fma.exemplo", "state=")
      stub_request(:post, plugin.oauth_config[:token]).with(body: hash_including("grant_type" => "authorization_code", "code" => "C1", "client_secret" => "csec-teste"))
                                                      .to_return(json("access_token" => "A1", "refresh_token" => "R-teste", "expires_in" => 3600))
      r = plugin.oauth_callback(i, { code: "C1", redirect_uri: "https://ma.exemplo/integracoes/oauth/retorno" })
      expect(r.alert).to be_nil
      Integrations.adopt!(i, i.found.to_h { |e| [ e["id"], "" ] })
      i
    end

    it "OauthPlugin: plugin falso de nuvem entra por stub_const; 401 renova o token uma vez" do
      fake = Class.new(Integrations::OauthPlugin) do
        describe key: "teste_nuvem", title: "Teste Nuvem", icon: "cloud", description: "Teste"
        texts en: { title: "Cloud test", description: "Test" }, es: { title: "Prueba nube", description: "Prueba" }
        oauth authorize: "https://nuvem.exemplo/oauth/authorize", token: "https://nuvem.exemplo/oauth/token", scope: "ler"
        def self.entries(i) = Array(api(i, :get, "https://nuvem.exemplo/api/coisas")["items"]).map { |c| entry(id: "n:#{c['id']}", name: c["nome"], points: [ point("power", unit: "W") ]) }
        def self.read(device) = { "power" => api(device.integration, :get, "https://nuvem.exemplo/api/coisas")["items"].first["w"] }
      end
      stub_const("Integrations::FakeNuvemPlugin", fake)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS + [ "FakeNuvemPlugin" ])
      stub_request(:get, "https://nuvem.exemplo/api/coisas").with(headers: { "Authorization" => "Bearer A1" }).to_return(json("items" => [ { "id" => 1, "nome" => "Teste Coisa", "w" => 7 } ]))
      i = oauth_add(fake)
      expect(pts(i)["power"].value).to eq(7)
      expect(i.secrets).to include("refresh_token" => "R-teste")

      stub_request(:get, "https://nuvem.exemplo/api/coisas").with(headers: { "Authorization" => "Bearer A1" }).to_return(status: 401, body: "{}")
      stub_request(:get, "https://nuvem.exemplo/api/coisas").with(headers: { "Authorization" => "Bearer A2" }).to_return(json("items" => [ { "id" => 1, "w" => 9 } ]))
      stub_request(:post, "https://nuvem.exemplo/oauth/token").with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "R-teste"))
                                                              .to_return(json("access_token" => "A2", "expires_in" => 3600))
      fake.poll(i.devices.first)
      expect(pts(i)["power"].value).to eq(9)
      expect(ApplicationController.helpers.integration_connect_partial(fake)).to eq("web/integrations/connect/oauth")
    end

    it "SmartThings: capacidades viram pontos pelo mapa YAML e o comando sai pela capacidade" do
      api = "https://api.smartthings.com/v1"
      stub_request(:get, "#{api}/locations").to_return(json("items" => [ { "locationId" => "L1" } ]))
      stub_request(:get, "#{api}/locations/L1/rooms").to_return(json("items" => [ { "roomId" => "R1", "name" => "Teste Sala" } ]))
      stub_request(:get, "#{api}/devices").to_return(json("items" => [
        { "deviceId" => "d1", "label" => "Teste Abajur", "roomId" => "R1", "components" => [ { "id" => "main", "capabilities" => [ { "id" => "switch" }, { "id" => "switchLevel" }, { "id" => "refresh" } ] } ] },
        { "deviceId" => "d2", "label" => "Teste Sensor", "components" => [ { "id" => "main", "capabilities" => [ { "id" => "contactSensor" }, { "id" => "temperatureMeasurement" } ] } ] },
        { "deviceId" => "d3", "label" => "Teste Hub", "components" => [ { "id" => "main", "capabilities" => [ { "id" => "bridge" } ] } ] }
      ]))
      stub_request(:get, "#{api}/devices/d1/status").to_return(json("components" => { "main" => { "switch" => { "switch" => { "value" => "on" } }, "switchLevel" => { "level" => { "value" => 60 } } } }))
      stub_request(:get, "#{api}/devices/d2/status").to_return(json("components" => { "main" => { "contactSensor" => { "contact" => { "value" => "open" } },
                                                                                                   "temperatureMeasurement" => { "temperature" => { "value" => 77, "unit" => "F" } } } }))
      cmd = stub_request(:post, "#{api}/devices/d1/commands").with(body: { commands: [ { capability: "switchLevel", command: "setLevel", arguments: [ 30 ], component: "main" } ] })
                                                              .to_return(json({}))
      i = oauth_add(Integrations::SmartthingsPlugin)
      by = i.devices.index_by(&:name)
      expect(by.keys).to contain_exactly("Teste Abajur", "Teste Sensor")
      expect(by["Teste Abajur"].area&.name).to be_nil # sugestão de área fica no inventário
      expect(i.found.find { |e| e["name"] == "Teste Abajur" }["room"]).to eq("Teste Sala")
      lamp = by["Teste Abajur"].points.index_by { |p| p.address["field"] }
      sensor = by["Teste Sensor"].points.index_by { |p| p.address["field"] }
      expect([ lamp["switch"].value, lamp["switchLevel"].value, sensor["contactSensor"].value, sensor["temperatureMeasurement"].value ]).to eq([ true, 60, true, 25.0 ])
      expect(sensor["contactSensor"].name).to eq("Aberto")
      run(lamp["switchLevel"], "set", 30)
      expect(cmd).to have_been_requested
    end

    it "Netatmo: estação com módulos e cômodo com temperatura alvo" do
      api = "https://api.netatmo.com/api"
      stub_request(:get, "#{api}/getstationsdata").to_return(json("body" => { "devices" => [
        { "_id" => "70:ee", "module_name" => "Teste Interno", "type" => "NAMain", "dashboard_data" => { "Temperature" => 22.5, "Humidity" => 55, "CO2" => 610, "Noise" => 38, "Pressure" => 1013 },
          "modules" => [ { "_id" => "02:00", "module_name" => "Teste Externo", "type" => "NAModule1", "battery_percent" => 70, "dashboard_data" => { "Temperature" => 18.1, "Humidity" => 80 } } ] }
      ] }))
      stub_request(:get, "#{api}/homesdata").to_return(json("body" => { "homes" => [ { "id" => "H1", "rooms" => [ { "id" => "r1", "name" => "Teste Quarto" } ] } ] }))
      stub_request(:get, "#{api}/homestatus?home_id=H1").to_return(json("body" => { "home" => { "rooms" => [ { "id" => "r1", "therm_measured_temperature" => 19.5, "therm_setpoint_temperature" => 20 } ] } }))
      set = stub_request(:post, "#{api}/setroomthermpoint").with(body: hash_including("home_id" => "H1", "room_id" => "r1", "mode" => "manual", "temp" => 21.5)).to_return(json("status" => "ok"))
      i = oauth_add(Integrations::NetatmoPlugin)
      by = i.devices.index_by(&:name)
      inner = by["Teste Interno"].points.index_by { |p| p.address["field"] }
      outer = by["Teste Externo"].points.index_by { |p| p.address["field"] }
      room = by["Teste Quarto"].points.index_by { |p| p.address["field"] }
      expect([ inner["co2"].value, inner["noise"].value, outer["temperature"].value, outer["battery"].value, room["setpoint"].value ]).to eq([ 610, 38, 18.1, 70, 20 ])
      run(room["setpoint"], "set", 21.5)
      expect(set).to have_been_requested
    end

    it "Home Connect: estado, porta, programa e tempo que falta; liga pelo PowerState" do
      api = "https://api.home-connect.com/api/homeappliances"
      stub_request(:get, api).with(headers: { "Accept" => "application/vnd.bsh.sdk.v1+json" })
                             .to_return(json("data" => { "homeappliances" => [ { "haId" => "BOSCH-1", "name" => "Teste Lava-louças", "type" => "Dishwasher", "brand" => "Bosch", "connected" => true } ] }))
      stub_request(:get, "#{api}/BOSCH-1/status").to_return(json("data" => { "status" => [ { "key" => "BSH.Common.Status.OperationState", "value" => "BSH.Common.EnumType.OperationState.Run" },
                                                                                             { "key" => "BSH.Common.Status.DoorState", "value" => "BSH.Common.EnumType.DoorState.Closed" } ] }))
      stub_request(:get, "#{api}/BOSCH-1/settings/BSH.Common.Setting.PowerState").to_return(json("data" => { "value" => "BSH.Common.EnumType.PowerState.On" }))
      stub_request(:get, "#{api}/BOSCH-1/programs/active").to_return(json("data" => { "key" => "Dishcare.Dishwasher.Program.Eco50",
                                                                                         "options" => [ { "key" => "BSH.Common.Option.RemainingProgramTime", "value" => 5400 },
                                                                                                        { "key" => "BSH.Common.Option.ProgramProgress", "value" => 40 } ] }))
      off = stub_request(:put, "#{api}/BOSCH-1/settings/BSH.Common.Setting.PowerState").with(body: { data: { key: "BSH.Common.Setting.PowerState", value: "BSH.Common.EnumType.PowerState.Off" } })
                                                                                      .to_return(status: 204, body: "")
      i = oauth_add(Integrations::HomeConnectPlugin)
      p = pts(i)
      expect([ p["power"].value, p["operation"].value, p["door"].value, p["program"].value, p["remaining"].value, p["progress"].value ]).to eq([ true, "Run", false, "Eco50", 90, 40 ])
      run(p["power"], "off")
      expect(off).to have_been_requested
    end

    it "Google Nest: termostato pela SDM (projeto do dono na URL do login)" do
      base = "https://smartdevicemanagement.googleapis.com/v1/enterprises/proj-teste"
      dev = { "name" => "enterprises/proj-teste/devices/T1", "type" => "sdm.devices.types.THERMOSTAT",
              "traits" => { "sdm.devices.traits.Info" => { "customName" => "Teste Termostato" }, "sdm.devices.traits.Temperature" => { "ambientTemperatureCelsius" => 23.44 },
                            "sdm.devices.traits.Humidity" => { "ambientHumidityPercent" => 48 }, "sdm.devices.traits.ThermostatMode" => { "mode" => "COOL", "availableModes" => %w[COOL OFF] },
                            "sdm.devices.traits.ThermostatTemperatureSetpoint" => { "coolCelsius" => 24.0 } } }
      stub_request(:get, "#{base}/devices").to_return(json("devices" => [ dev, { "name" => "enterprises/proj-teste/devices/C1", "type" => "sdm.devices.types.CAMERA" } ]))
      stub_request(:get, "https://smartdevicemanagement.googleapis.com/v1/enterprises/proj-teste/devices/T1").to_return(json(dev))
      set = stub_request(:post, "https://smartdevicemanagement.googleapis.com/v1/enterprises/proj-teste/devices/T1:executeCommand")
            .with(body: { command: "sdm.devices.commands.ThermostatTemperatureSetpoint.SetCool", params: { coolCelsius: 22.5 } }).to_return(json({}))
      expect(Integrations::NestPlugin.authorize_url(Integration.new(settings: { "project_id" => "proj-teste" }))).to eq("https://nestservices.google.com/partnerconnections/proj-teste/auth")
      i = oauth_add(Integrations::NestPlugin, project_id: "proj-teste")
      expect(i.devices.map(&:name)).to contain_exactly("Teste Termostato", "Nest") # resto: a câmera também entra (vídeo pelo go2rtc)
      p = i.devices.find_by!(name: "Teste Termostato").points.reload.index_by { |x| x.address["field"] }
      expect([ p["temperature"].value, p["humidity"].value, p["mode"].value, p["cool"].value, p["mode"].options ]).to eq([ 23.4, 48, "COOL", 24.0, %w[COOL OFF] ])
      run(p["cool"], "set", 22.5)
      expect(set).to have_been_requested
    end

    it "Ecowitt: o gateway manda as leituras (formato Ecowitt) e os pontos nascem; outra PASSKEY é recusada" do
      o = Integrations::EcowittPlugin.setup(site, form({}))
      expect(o.to).to eq(:panel)
      i = o.integration
      expect(Integrations::EcowittPlugin.panel_locals(i, {})[:rows].first.last).to eq("/mensageiros/#{i.id}")
      req = ->(h) { ActionDispatch::Request.new(Rack::MockRequest.env_for("/mensageiros/#{i.id}", method: "POST", params: h)) }
      body = { "PASSKEY" => "ABC123", "stationtype" => "GW2000A", "tempf" => "77.0", "humidity" => "60", "baromrelin" => "29.92", "windspeedmph" => "10",
               "dailyrainin" => "0.5", "temp1f" => "68", "soilmoisture2" => "33", "model" => "GW2000A" }
      expect(Integrations::EcowittPlugin.webhook(i, req.call(body))).to eq([ 200, "OK" ])
      p = pts(i)
      expect([ p["temperature"].value, p["humidity"].value, p["pressure"].value, p["wind_speed"].value, p["rain_day"].value, p["channel_temperature:1"].value, p["soil:2"].value ])
        .to eq([ 25.0, 60.0, 1013.2, 16.1, 12.7, 20.0, 33.0 ])
      expect(p["soil:2"].name).to eq("Umidade do solo 2")
      expect(Integrations::EcowittPlugin.webhook(i, req.call(body.merge("PASSKEY" => "OUTRO")))[0]).to eq(403)
      expect(Integrations::EcowittPlugin.webhook(i, req.call(body.merge("tempf" => "86")))).to eq([ 200, "OK" ])
      expect(pts(i)["temperature"].value).to eq(30.0)
    end

    it "Overkiz: local com token (persiana com posição e botões) e nuvem com login por formulário" do
      devices = [ { "deviceURL" => "io://1234/567", "label" => "Teste Persiana", "controllableName" => "io:RollerShutterGenericIOComponent",
                    "definition" => { "uiClass" => "RollerShutter", "commands" => %w[open close stop setClosure].map { |c| { "commandName" => c } } },
                    "states" => [ { "name" => "core:ClosureState", "value" => 30 } ] },
                  { "deviceURL" => "internal://1234/pod/0", "label" => "Teste Box", "definition" => { "uiClass" => "Pod", "commands" => [] } } ]
      local = "https://gateway-1234.local:8443/enduser-mobile-web/1/enduserAPI"
      stub_request(:get, "#{local}/setup/devices").with(headers: { "Authorization" => "Bearer tok-teste" }).to_return(json(devices))
      exec = stub_request(:post, "#{local}/exec/apply").with(body: hash_including("actions" => [ { "deviceURL" => "io://1234/567", "commands" => [ { "name" => "setClosure", "parameters" => [ 20 ] } ] } ]))
                                                       .to_return(json("execId" => "e1"))
      i = add(Integrations::OverkizPlugin, server: "local", host: "gateway-1234.local", token: "tok-teste")
      p = pts(i)
      expect(p.keys).to contain_exactly("position", "open", "close", "stop")
      expect(p["position"].value).to eq(70)
      run(p["position"], "set", 80)
      expect(exec).to have_been_requested

      cloud = "https://ha101-1.overkiz.com/enduser-mobile-web/enduserAPI"
      stub_request(:post, "#{cloud}/login").with(body: { userId: "teste@exemplo.com", userPassword: "senha-teste" }).to_return(status: 200, body: "{}", headers: { "Set-Cookie" => "JSESSIONID=J1; Path=/" })
      stub_request(:get, "#{cloud}/setup/devices").with(headers: { "Cookie" => "JSESSIONID=J1" }).to_return(json(devices))
      c = Integrations::OverkizPlugin.setup(site, form(server: "somfy_europe", username: "teste@exemplo.com", password: "senha-teste"))
      expect([ c.alert, c.integration.found.size ]).to eq([ nil, 1 ])
    end

    it "Ring: pede o código de 2 etapas, guarda só o refresh token e lê bateria e eventos" do
      stub_request(:post, "https://oauth.ring.com/oauth/token").with(headers: { "2fa-support" => "true" }) { |r| !r.headers.key?("2fa-Code") }.to_return(status: 412, body: "{}")
      stub_request(:post, "https://oauth.ring.com/oauth/token").with(headers: { "2fa-code" => "123456" })
                                                              .to_return(json("access_token" => "A1", "refresh_token" => "R1-teste", "expires_in" => 3600))
      stub_request(:get, "https://api.ring.com/clients_api/ring_devices").to_return(json("doorbots" => [ { "id" => 9, "description" => "Teste Porta", "kind" => "doorbell_v3", "battery_life" => "88" } ]))
      stub_request(:get, "https://api.ring.com/clients_api/doorbots/9/history?limit=5").to_return(json([ { "created_at" => "2026-11-03T12:00:00Z", "kind" => "ding", "answered" => false } ]))
      o = Integrations::RingPlugin.setup(site, form(username: "teste@exemplo.com", password: "senha-teste"))
      expect([ o.to, o.alert ]).to eq([ :connect, Integrations::RingPlugin.text(:need_code) ])
      r = Integrations::RingPlugin.login(o.integration, form(username: "teste@exemplo.com", password: "senha-teste", otp: "123456"))
      i = r.integration
      expect(r.alert).to be_nil
      expect(i.secrets).to eq("access_token" => "A1", "refresh_token" => "R1-teste", "expires_at" => i.secrets["expires_at"])
      Integrations.adopt!(i, i.found.to_h { |e| [ e["id"], "" ] })
      p = pts(i)
      expect([ p["battery"].value, p["ding"].value ]).to eq([ 88, { "at" => "2026-11-03T12:00:00Z", "answered" => false } ])
    end
  end

  describe "rede e dados, parte 2 (D10/D13)" do
    it "UniFi Network: clientes como presença, aparelhos UniFi e bloquear cliente (UniFi OS)" do
      root = "https://192.0.2.20:443"
      stub_request(:post, "#{root}/api/auth/login").with(body: { username: "teste", password: "teste" })
                                                   .to_return(status: 200, body: "{}", headers: { "Set-Cookie" => "TOKEN=t1; path=/", "X-CSRF-Token" => "csrf1" })
      net = "#{root}/proxy/network/api/s/default"
      stub_request(:get, "#{net}/stat/sta").with(headers: { "Cookie" => "TOKEN=t1" })
                                           .to_return { json("data" => [ { "mac" => "aa:bb:cc:00:00:01", "name" => "Teste Celular", "essid" => "Casa", "last_seen" => Time.current.to_i } ]) }
      stub_request(:get, "#{net}/stat/device").to_return(json("data" => [ { "mac" => "f0:9f:00:00:00:01", "name" => "Teste AP", "model" => "U6LR", "type" => "uap" } ]))
      stub_request(:get, "#{net}/stat/device/f0:9f:00:00:00:01").to_return(json("data" => [ { "state" => 1, "num_sta" => 12, "uptime" => 7200 } ]))
      stub_request(:get, "#{net}/rest/user").to_return(json("data" => [ { "mac" => "aa:bb:cc:00:00:01", "blocked" => false } ]))
      block = stub_request(:post, "#{net}/cmd/stamgr").with(body: { cmd: "block-sta", mac: "aa:bb:cc:00:00:01" }, headers: { "X-CSRF-Token" => "csrf1" }).to_return(json("data" => []))
      i = add(Integrations::UnifiPlugin, host: "192.0.2.20", username: "teste", password: "teste")
      by = i.devices.index_by(&:name)
      phone = by["Teste Celular"].points.index_by { |p| p.address["field"] }
      ap = by["Teste AP"].points.index_by { |p| p.address["field"] }
      expect([ phone["home"].value, phone["home"].device_class, phone["blocked"].value ]).to eq([ true, "presence", false ])
      expect([ ap["online"].value, ap["clients"].value, ap["uptime"].value ]).to eq([ true, 12, 2.0 ])
      run(phone["blocked"], "on")
      expect(block).to have_been_requested
    end

    it "Speedtest: latência, download e upload contra o servidor da lista" do
      stub_request(:get, %r{www\.speedtest\.net/api/js/servers}).to_return(json([ { "id" => "1", "host" => "speed.exemplo:8080", "name" => "São Paulo", "sponsor" => "Teste" } ]))
      stub_request(:get, %r{https://speed\.exemplo:8080/speedtest/latency\.txt}).to_return(status: 200, body: "test=test")
      stub_request(:get, %r{https://speed\.exemplo:8080/download\?}).to_return(status: 200, body: "x" * 1000)
      up = stub_request(:post, %r{https://speed\.exemplo:8080/upload\?}).to_return(status: 200, body: "size=5000000")
      i = add(Integrations::SpeedtestPlugin, {})
      p = pts(i)
      expect(p.keys).to contain_exactly("download", "upload", "ping")
      expect([ p["download"].value, p["upload"].value, p["ping"].value ]).to all(be_a(Numeric))
      expect(p["download"].unit).to eq("Mbit/s")
      expect(up).to have_been_requested
      expect(i.devices.first.model).to eq("Teste · São Paulo")
    end

    it "IPP: Get-Printer-Attributes binário, estado e nível de cada toner" do
      ipp = Integrations::IppPlugin
      int = ->(tag, name, v) { [ tag, name.bytesize ].pack("Cn") + name + [ 4, v ].pack("nl>") }
      reply = [ 2, 0, 0, 1 ].pack("CCnN") + [ 0x04 ].pack("C") +
              ipp.attr(0x41, "printer-make-and-model", "Brother HL-L2350DW") + ipp.attr(0x45, "printer-uuid", "urn:uuid:teste-1") +
              int.(0x23, "printer-state", 4) + ipp.attr(0x41, "marker-names", "Black Toner") + ipp.attr(0x41, "", "Drum") +
              int.(0x21, "marker-levels", 70) + int.(0x21, "", -3) + [ 0x03 ].pack("C")
      req = stub_request(:post, "http://192.0.2.30:631/ipp/print").with(headers: { "Content-Type" => "application/ipp" }) { |r| r.body.b.include?("printer-uri") }
                                                                   .to_return(status: 200, body: reply)
      i = add(ipp, host: "192.0.2.30")
      p = pts(i)
      expect(i.devices.first.name).to eq("Brother HL-L2350DW")
      expect([ p["state"].value, p["marker:0"].name, p["marker:0"].value, p["marker:1"].value ]).to eq([ "Imprimindo", "Black Toner", 70, nil ])
      expect(req).to have_been_requested.at_least_once
    end

    it "InfluxDB: relator do StateReport manda a leitura nova em line protocol (2.x)" do
      ping = stub_request(:post, "http://192.0.2.40:8086/api/v2/write?bucket=casa&org=teste&precision=s").with(headers: { "Authorization" => "Token tok-teste" }).to_return(status: 204, body: "")
      o = Integrations::InfluxdbPlugin.setup(site, form(url: "http://192.0.2.40:8086", org: "teste", bucket: "casa", token: "tok-teste"))
      expect([ o.to, o.alert ]).to eq([ :index, nil ])
      expect(ping).to have_been_requested
      device = site.devices.create!(name: "Teste Medidor", driver: "virtual")
      point = device.points.create!(site: site, name: "Teste Potência", key: "teste.potencia", capability: "measure", unit: "W")
      point.report!(42.5)
      expect(Integrations::InfluxdbPlugin.wants?(point)).to be(true)
      Integrations::InfluxdbPlugin.report!(site, [ point ])
      expect(a_request(:post, %r{/api/v2/write}).with(body: /\AW,entity_id=teste.potencia,domain=measure value=42.5 \d+\z/)).to have_been_made
      expect(StateReport.reporters).to include(Integrations::InfluxdbPlugin)
    end

    it "Modbus TCP: registradores descritos em texto viram pontos; holding e coil recebem comando" do
      regs = { 30_775 => [ 0xFFFF, 0xFF38 ], 400 => [ 215 ], 100 => [ 0x41C8, 0x0000 ] }
      coils = { 12 => false }
      writes = []
      port = tcp_server do |s|
        while (head = s.read(7))
          tid, _p, len, unit = head.unpack("nnnC")
          pdu = s.read(len - 1)
          fn, addr, n = pdu.unpack("Cnn")
          if fn == 5 || fn == 6
            writes << [ fn, addr, n ]
            fn == 5 ? coils[addr] = (n == 0xFF00) : regs[addr] = [ n ]
            body = pdu
          elsif fn == 1
            body = [ fn, 1, coils[addr] ? 1 : 0 ].pack("CCC")
          else
            words = (regs[addr] || ([ 0 ] * n)).first(n)
            body = [ fn, words.size * 2, *words ].pack("CCn*")
          end
          s.write([ tid, 0, body.bytesize + 1, unit ].pack("nnnC") + body)
        end
      end
      text = "Teste Potência; 30775; input; int32; 1; W\nTeste Bomba; 12; coil\nTeste Alvo; 400; holding; int16; 0,1; °C\nTeste Fluxo; 100; holding; float32; 1; m³/h"
      i = add(Integrations::ModbusPlugin, host: "127.0.0.1", port: port, registers: text)
      p = pts(i)
      expect([ p["input:30775"].value, p["coil:12"].value, p["holding:400"].value, p["holding:100"].value ]).to eq([ -200, false, 21.5, 25.0 ])
      expect([ p["holding:400"].capability, p["holding:100"].capability, p["coil:12"].capability ]).to eq(%w[setpoint measure onoff])
      run(p["holding:400"], "set", 23)
      run(p["coil:12"], "on")
      expect(writes).to eq([ [ 6, 400, 230 ], [ 5, 12, 0xFF00 ] ])
      expect(Integrations::ModbusPlugin.setup(site, form(host: "127.0.0.1", registers: "sem ponto e vírgula")).alert).to include("Linha 1")
    end

    it "OneDrive: a integração vira o destino do backup (sessão de upload em pedaços, listar, apagar)" do
      o = Integrations::OnedrivePlugin.setup(site, form(client_id: "cid-teste", client_secret: "csec-teste"))
      expect(o.to).to eq(:connect)
      stub_request(:post, Integrations::OnedrivePlugin.oauth_config[:token]).to_return(json("access_token" => "A1", "refresh_token" => "R-teste", "expires_in" => 3600))
      stub_request(:get, "https://graph.microsoft.com/v1.0/me/drive/special/approot").to_return(json("id" => "root"))
      r = Integrations::OnedrivePlugin.oauth_callback(o.integration, { code: "C1", redirect_uri: "https://ma.exemplo/x" })
      expect(r.notice).to include("OneDrive")
      expect(Backups::Destinations::Onedrive.connected?).to be(true)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("BACKUP_OFFSITE_URL").and_return(nil)
      expect(Backups.url).to eq("onedrive://approot") unless Backups::Destinations::GoogleDrive.connected?

      stub_request(:post, %r{approot:/ma-20261103\.sql\.gz\.enc:/createUploadSession}).to_return(json("uploadUrl" => "https://up.exemplo/sessao/1"))
      put = stub_request(:put, "https://up.exemplo/sessao/1").to_return(status: 201, body: "{}")
      stub_request(:get, %r{approot/children}).to_return(json("value" => [ { "id" => "F1", "name" => "ma-20261103.sql.gz.enc", "size" => 10 }, { "id" => "X", "name" => "outro.txt" } ]))
      del = stub_request(:delete, "https://graph.microsoft.com/v1.0/me/drive/items/F1").to_return(status: 204, body: "")
      dest = Backups::Destinations::Onedrive.new(URI("onedrive://approot"))
      file = Rails.root.join("tmp", "teste-onedrive.bin")
      File.binwrite(file, "x" * 100)
      dest.upload(file.to_s, "ma-20261103.sql.gz.enc")
      expect(put.with(headers: { "Content-Range" => "bytes 0-99/100" })).to have_been_requested
      expect(dest.list).to include("ma-20261103.sql.gz.enc")
      dest.delete("ma-20261103.sql.gz.enc")
      expect(del).to have_been_requested
    ensure
      FileUtils.rm_f(file) if file
    end

    it "UPnP/IGD: IP externo, conexão, bytes e a taxa entre duas leituras" do
      allow(Ssdp).to receive(:search).and_return([ { "host" => "192.0.2.1", "txt" => { "location" => "http://192.0.2.1:5000/rootDesc.xml" } } ])
      desc = "<root><device><UDN>uuid:igd-1</UDN><friendlyName>Teste Roteador</friendlyName><modelName>R1</modelName><manufacturer>Teste</manufacturer>" \
             "<service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType><controlURL>/ctl/CmnIfCfg</controlURL></service>" \
             "<service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/ctl/IPConn</controlURL></service></device></root>"
      stub_request(:get, "http://192.0.2.1:5000/rootDesc.xml").to_return(status: 200, body: desc)
      rx = [ 1_000_000_000 ]
      stub_request(:post, %r{192\.0\.2\.1:5000/ctl/}).to_return do |req|
        body = case req.headers["Soapaction"].to_s.split("#").last
        when "GetStatusInfo" then "<NewConnectionStatus>Connected</NewConnectionStatus><NewUptime>7200</NewUptime>"
        when "GetExternalIPAddress" then "<NewExternalIPAddress>203.0.113.7</NewExternalIPAddress>"
        when "GetTotalBytesReceived" then "<NewTotalBytesReceived>#{rx.first}</NewTotalBytesReceived>"
        else "<NewTotalBytesSent>500000000</NewTotalBytesSent>"
        end
        { status: 200, body: "<s:Envelope><s:Body>#{body}</s:Body></s:Envelope>" }
      end
      i = travel_to(Time.zone.parse("2026-11-03 10:00:00")) { add(Integrations::UpnpPlugin, host: "192.0.2.1") }
      p = pts(i)
      expect([ p["connected"].value, p["external_ip"].value, p["uptime"].value, p["received"].value, p["rate_down"].value ]).to eq([ true, "203.0.113.7", 2.0, 1.0, nil ])
      rx[0] += 125_000_000 # 1 Gbit em 10 s
      travel_to(Time.zone.parse("2026-11-03 10:00:10")) { Integrations::UpnpPlugin.poll(i.devices.first) }
      expect(pts(i)["rate_down"].value).to eq(100.0)
    end

    it "FRITZ!Box TR-064: digest, Wi-Fi liga/desliga e aparelhos como presença" do
      calls = []
      stub_request(:post, %r{http://fritz\.box:49000/upnp/control/}).to_return do |req|
        action = req.headers["Soapaction"].to_s.split("#").last
        calls << [ action, req.body[/<NewEnable>(\d)</, 1] ].compact
        next({ status: 401, headers: { "WWW-Authenticate" => 'Digest realm="F!Box SOAP-Auth", nonce="N1", algorithm=MD5, qop="auth"' }, body: "" }) unless req.headers["Authorization"].to_s.start_with?("Digest ")

        body = case action
        when "GetInfo"
                 if req.uri.path.include?("wlanconfig")
                   k = req.uri.path[/\d\z/].to_i
                   k <= 2 ? "<NewSSID>Teste Wi-Fi #{k}</NewSSID><NewEnable>1</NewEnable>" : nil
                 else "<NewModelName>FRITZ!Box 7590</NewModelName><NewSerialNumber>S1</NewSerialNumber><NewUpTime>36000</NewUpTime><NewSoftwareVersion>7.57</NewSoftwareVersion>"
                 end
        when "GetHostNumberOfEntries" then "<NewHostNumberOfEntries>1</NewHostNumberOfEntries>"
        when "GetGenericHostEntry" then "<NewMACAddress>AA:BB:CC:00:00:09</NewMACAddress><NewHostName>Teste-Celular</NewHostName><NewActive>1</NewActive>"
        when "GetSpecificHostEntry" then "<NewActive>0</NewActive>"
        when "GetExternalIPAddress" then "<NewExternalIPAddress>203.0.113.9</NewExternalIPAddress>"
        when "SetEnable" then ""
        end
        body.nil? ? { status: 500, body: "" } : { status: 200, body: "<s:Envelope><s:Body>#{body}</s:Body></s:Envelope>" }
      end
      i = add(Integrations::FritzPlugin, username: "teste", password: "teste")
      by = i.devices.index_by(&:name)
      router = by["FRITZ!Box 7590"].points.index_by { |p| p.address["field"] }
      phone = by["Teste-Celular"].points.index_by { |p| p.address["field"] }
      expect([ router["uptime"].value, router["external_ip"].value, router["wifi:1"].name, router["wifi:2"].value, phone["home"].value ])
        .to eq([ 10.0, "203.0.113.9", "Teste Wi-Fi 1", true, false ])
      run(router["wifi:2"], "off")
      expect(calls).to include([ "SetEnable", "0" ])
    end

    it "Music Assistant: players pela API WebSocket, comandos por player" do
      sent = []
      players = [ { "player_id" => "sonos_1", "display_name" => "Teste Sala", "available" => true, "state" => "playing", "volume_level" => 30,
                    "current_media" => { "title" => "Teste Faixa", "artist" => "Teste Artista" } } ]
      ws = Object.new
      ws.define_singleton_method(:connect) { self }
      ws.define_singleton_method(:close) { nil }
      inbox = []
      ws.define_singleton_method(:send_json) do |m|
        m = JSON.parse(m.to_json)
        sent << m
        inbox << { "event" => "player_updated" } << { "message_id" => m["message_id"], "result" => m["command"] == "players/all" ? players : nil }
      end
      ws.define_singleton_method(:read_json) { |_t = nil| inbox.shift }
      allow(WsClient).to receive(:new).with("ws://192.0.2.50:8095/ws").and_return(ws)
      i = add(Integrations::MusicAssistantPlugin, host: "192.0.2.50")
      media = pts(i)["media"]
      expect(media.value).to eq("state" => "playing", "volume" => 30, "title" => "Teste Faixa", "artist" => "Teste Artista")
      run(media, "volume", 45)
      run(media, "play_media", "library://track/12")
      expect(sent.map { |m| [ m["command"], m["args"] ] }).to include([ "players/cmd/volume_set", { "player_id" => "sonos_1", "volume_level" => 45 } ],
                                                                       [ "player_queues/play_media", { "queue_id" => "sonos_1", "media" => "library://track/12" } ])
    end

    it "Plex: assistindo agora, bibliotecas e o player da sessão com pausar" do
      base = "http://192.0.2.60:32400"
      h = { "X-Plex-Token" => "tok-teste" }
      stub_request(:get, "#{base}/identity").with(headers: h).to_return(json("MediaContainer" => { "machineIdentifier" => "srv1" }))
      stub_request(:get, "#{base}/library/sections").to_return(json("MediaContainer" => { "Directory" => [ { "key" => "1", "title" => "Filmes" } ] }))
      stub_request(:get, "#{base}/library/sections/1/all").to_return(json("MediaContainer" => { "totalSize" => 321 }))
      stub_request(:get, "#{base}/status/sessions").to_return(json("MediaContainer" => { "Metadata" => [
        { "title" => "Teste Filme", "Player" => { "machineIdentifier" => "tv1", "title" => "Teste TV", "product" => "Plex for Android", "state" => "playing" } }
      ] }))
      pause = stub_request(:get, "#{base}/player/playback/pause?type=video").with(headers: { "X-Plex-Target-Client-Identifier" => "tv1" }).to_return(json({}))
      i = add(Integrations::PlexPlugin, host: "192.0.2.60", token: "tok-teste")
      by = i.devices.index_by(&:name)
      server = by[i.name].points.index_by { |p| p.address["field"] }
      expect([ server["watching"].value, server["library:1"].value, server["library:1"].name ]).to eq([ 1, 321, "Biblioteca: Filmes" ])
      media = by["Teste TV"].points.first
      expect(media.value).to include("state" => "playing", "title" => "Teste Filme")
      run(media, "pause")
      expect(pause).to have_been_requested
    end
  end
end
