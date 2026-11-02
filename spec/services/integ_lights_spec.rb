require "rails_helper"

# integ: luz e casa (WLED, Hue, Yeelight, SwitchBot) e Shelly EM. Respostas
# gravadas (WebMock) e um servidor TCP de mentira na própria máquina (Yeelight).
RSpec.describe "Luz e casa (integ)" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def json(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  def form(h) = ActionController::Parameters.new(h)

  def add(plugin, h)
    stub_const("Integrations::PLUGINS", Integrations::PLUGINS | [ plugin.name.demodulize ])
    o = plugin.setup(site, form(h))
    expect(o.alert).to be_nil
    Integrations.adopt!(o.integration, o.integration.found.to_h { |e| [ e["id"], "" ] })
    o.integration
  end

  def run(point, command, value = nil) = ExecuteCommandJob.perform_now(Points::Command.call(point, command, value, source: "web").id)

  describe "WLED" do
    let(:base) { "http://10.0.0.40:80" }
    let(:state) { { "on" => true, "bri" => 128, "seg" => [ { "fx" => 1, "col" => [ [ 255, 0, 0 ], [ 0, 0, 0 ] ] } ] } }

    before do
      stub_request(:get, "#{base}/json").to_return(json("state" => state, "info" => { "name" => "Fita da TV", "mac" => "aabbccddeeff", "ver" => "0.15.0", "arch" => "esp32" },
                                                        "effects" => %w[Solid Blink Breathe]))
      stub_request(:get, "#{base}/json/state").to_return(json(state))
    end

    it "liga, brilho, cor e efeito pela JSON API" do
      add(Integrations::WledPlugin, host: "10.0.0.40")
      d = site.devices.find_by!(driver: "wled")
      pts = d.points.index_by(&:name)
      expect(pts.keys).to contain_exactly("Luz", "Brilho", "Cor", "Efeito")
      Drivers::Wled.poll(d)
      expect(pts["Brilho"].reload.value).to eq(128)
      expect(pts["Cor"].reload.value).to include("mode" => "hs", "h" => 0.0, "s" => 100.0)
      expect(pts["Efeito"].reload.value).to eq("Blink")

      set = stub_request(:post, "#{base}/json/state").with(body: { on: true, seg: [ { col: [ [ 0, 255, 0 ] ] } ] }.to_json).to_return(json("success" => true))
      fx = stub_request(:post, "#{base}/json/state").with(body: { seg: [ { fx: 2 } ] }.to_json).to_return(json("success" => true))
      run(pts["Cor"], "set", "#00ff00")
      run(pts["Efeito"], "select", "Breathe")
      expect([ set, fx ]).to all(have_been_requested)
    end
  end

  describe "Philips Hue" do
    let(:base) { "https://10.0.0.50:443" }
    let(:light) { { "id" => "l1", "owner" => { "rid" => "d1" }, "on" => { "on" => true }, "dimming" => { "brightness" => 42.5 }, "color" => { "xy" => { "x" => 0.6915, "y" => 0.3083 } } } }

    def res(type, data) = stub_request(:get, "#{base}/clip/v2/resource/#{type}").with(headers: { "hue-application-key" => "chave1" }).to_return(json("data" => data))

    before do
      res("device", [ { "id" => "d1", "metadata" => { "name" => "Abajur" }, "product_data" => { "product_name" => "Hue color lamp", "manufacturer_name" => "Signify" } },
                      { "id" => "d2", "metadata" => { "name" => "Sensor do corredor" }, "product_data" => {} }, { "id" => "d3", "metadata" => { "name" => "Bridge" } } ])
      res("light", [ light ])
      res("motion", [ { "id" => "m1", "owner" => { "rid" => "d2" }, "motion" => { "motion" => false } } ])
      res("temperature", [ { "id" => "t1", "owner" => { "rid" => "d2" }, "temperature" => { "temperature" => 22.8 } } ])
    end

    it "pareia pelo botão, guarda a chave cifrada, lê luz e sensores e comanda em xy" do
      press = stub_request(:post, "#{base}/api").to_return(json([ { "error" => { "type" => 101, "description" => "link button not pressed" } } ]))
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS | %w[HuePlugin])
      o = Integrations::HuePlugin.setup(site, form(host: "10.0.0.50"))
      expect(o.alert).to match(/botão redondo/)
      press.to_return(json([ { "success" => { "username" => "chave1", "clientkey" => "x" } } ]))
      integration = add(Integrations::HuePlugin, host: "10.0.0.50")
      expect(integration.secrets["app_key"]).to eq("chave1")
      expect(integration.settings.to_json).not_to include("chave1")

      lamp = site.devices.find_by!(external_id: "hue:d1")
      sensor = site.devices.find_by!(external_id: "hue:d2")
      expect(lamp.points.pluck(:name)).to contain_exactly("Luz", "Brilho", "Cor")
      expect(sensor.points.pluck(:name)).to contain_exactly("Movimento", "Temperatura")
      expect(site.devices.exists?(external_id: "hue:d3")).to be false # o próprio bridge não tem ponto

      stub_request(:get, "#{base}/clip/v2/resource/light/l1").to_return(json("data" => [ light ]))
      Drivers::Hue.poll(lamp)
      cor = lamp.points.find_by!(name: "Cor")
      expect([ cor.value["h"], 360 - cor.value["h"] ].min).to be < 3 # vermelho
      expect(lamp.points.find_by!(name: "Brilho").value).to eq(43)

      put = stub_request(:put, "#{base}/clip/v2/resource/light/l1").with(headers: { "hue-application-key" => "chave1" }) do |req|
        body = JSON.parse(req.body)
        body["on"] == { "on" => true } && body.dig("color", "xy", "x").between?(0.13, 0.18) # azul
      end.to_return(json("data" => []))
      run(cor, "set", "#0000ff")
      expect(put).to have_been_requested
      Drivers::Hue.rgb_of(*Drivers::Hue.xy_of(255, 0, 0).values_at(:x, :y)).zip([ 255, 0, 0 ]).each { |got, want| expect(got).to be_within(3).of(want) }
    end
  end

  describe "Yeelight" do
    it "lê e comanda pela LAN (servidor TCP de mentira em 127.0.0.1)" do
      server = TCPServer.new("127.0.0.1", 0)
      got = Queue.new
      state = { "power" => "off", "bright" => "40", "rgb" => "16711680", "name" => "Fita do quarto", "model" => "strip1" }
      thread = Thread.new do
        loop do
          s = server.accept
          req = JSON.parse(s.gets)
          got << req
          if req["method"] == "get_prop"
            s.write({ "method" => "props", "params" => { "power" => "on" } }.to_json + "\r\n") # notificação no meio: ignorada
            s.write({ "id" => 1, "result" => req["params"].map { |k| state[k] } }.to_json + "\r\n")
          else
            state["power"] = req["params"][0] if req["method"] == "set_power"
            s.write({ "id" => 1, "result" => [ "ok" ] }.to_json + "\r\n")
          end
          s.close
        end
      end
      add(Integrations::YeelightPlugin, host: "127.0.0.1", port: server.addr[1])
      d = site.devices.find_by!(driver: "yeelight")
      expect(d.name).to eq("Fita do quarto")
      luz = d.points.find_by!(name: "Luz")
      Drivers::Yeelight.poll(d)
      expect(luz.reload.value).to be false
      expect(d.points.find_by!(name: "Cor").value).to include("h" => 0.0, "s" => 100.0)
      run(luz, "on")
      expect(Array.new(got.size) { got.pop }.map { |r| r["method"] }).to include("set_power")
      expect(luz.reload.value).to be true
    ensure
      thread&.kill
      server&.close
    end
  end

  describe "SwitchBot" do
    let(:url) { "https://api.switch-bot.com/v1.1" }

    it "assina o pedido, mapeia os tipos pelo device map e comanda pela nuvem" do
      sign = ->(req) { req.headers["Authorization"] == "tok" && req.headers["Sign"] == Drivers::Switchbot.headers("tok", "seg", t: req.headers["T"].to_i, nonce: req.headers["Nonce"])["sign"] }
      stub_request(:get, "#{url}/devices").with(&sign).to_return(json("statusCode" => 100, "body" => { "deviceList" => [
                                                                     { "deviceId" => "C1", "deviceName" => "Cortina da sala", "deviceType" => "Curtain3" },
                                                                     { "deviceId" => "M1", "deviceName" => "Termômetro", "deviceType" => "MeterPlus" },
                                                                     { "deviceId" => "X1", "deviceName" => "Desconhecido", "deviceType" => "Robot Vacuum S1" }
                                                                   ] }))
      add(Integrations::SwitchbotPlugin, token: "tok", secret: "seg")
      expect(site.devices.pluck(:name)).to contain_exactly("Cortina da sala", "Termômetro")
      curtain = site.devices.find_by!(name: "Cortina da sala")
      pos = curtain.points.find_by!(name: "Posição")

      stub_request(:get, "#{url}/devices/C1/status").to_return(json("statusCode" => 100, "body" => { "slidePosition" => 30 }))
      Drivers::Switchbot.poll(curtain)
      expect(pos.reload.value.to_f).to eq(70.0) # SwitchBot 30% fechada = 70% aberta

      cmd = stub_request(:post, "#{url}/devices/C1/commands").with(body: { command: "setPosition", parameter: "0,ff,0", commandType: "command" }.to_json)
                                                             .to_return(json("statusCode" => 100, "body" => {}))
      run(pos, "set", 100)
      expect(cmd).to have_been_requested
      expect(pos.reload.value.to_f).to eq(100.0)
    end

    it "token errado vira erro de credencial" do
      stub_request(:get, "#{url}/devices").to_return(status: 401, body: "{}")
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS | %w[SwitchbotPlugin])
      o = Integrations::SwitchbotPlugin.setup(site, form(token: "x", secret: "y"))
      expect(o.alert).to match(/recusou o acesso/)
    end
  end

  it "Shelly EM Gen2: fases, total e energia pelo mapa (só dado)" do
    pts = Shelly.points(2, { "em:0" => { "total_act_power" => 1500.5, "a_act_power" => 500, "a_voltage" => 220.1 }, "emdata:0" => { "total_act" => 123_456.0 } })
    expect(pts.map { |a| a["name"] }).to contain_exactly("Potência total", "Potência fase A", "Tensão fase A", "Energia consumida")
    expect(pts.find { |a| a["name"] == "Energia consumida" }).to include("unit" => "kWh", "scale" => 0.001, "state_class" => "total_increasing")
  end
end
