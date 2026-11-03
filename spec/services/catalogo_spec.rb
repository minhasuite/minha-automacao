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
  end
end
