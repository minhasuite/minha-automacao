require "rails_helper"

# integ2: ar-condicionado (Daikin, Midea, LG ThinQ), solar (SunSpec, Growatt),
# casa (IKEA Dirigera, Sonos, Govee), Z-Wave JS e proxy Bluetooth. Respostas
# gravadas (WebMock) e aparelhos de mentira em 127.0.0.1 (TCP/UDP); nada de
# rede real nem conta real.
RSpec.describe "Ecossistema 2 (integ2)" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }

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
  def pts(device) = device.points.reload.index_by(&:name)

  it "registra os plugins e drivers novos sem mexer no núcleo" do
    keys = %w[daikin midea lg_thinq sunspec growatt dirigera sonos govee zwave_js ble_proxy]
    expect(keys.map { |k| Integrations.plugin(k)&.driver }).to eq(keys)
    expect(keys.map { |k| Drivers::REGISTRY.key?(k) && Polling::DEVICES.key?(k) }).to all(be true)
  end

  describe "ar-condicionado (capacidade climate)" do
    it "um AC falso entra por stub_const e ganha os pontos comuns, o resumo e o comando" do
      fake = Class.new(Drivers::Climate) do
        def self.vendor = "fake_ac"
        def self.state = (@state ||= { "power" => false, "mode" => "Frio", "target" => 23.0, "fan" => "Auto", "current" => 26.5 })
        def self.read(_device) = state.dup
        def self.write(_device, field, value) = state[field] = value
      end
      plugin = Class.new(Integrations::LanPlugin) do
        describe key: "fake_ac", title: "AC de teste", icon: "sun", description: "Teste"
        def self.probe(i) = Drivers::REGISTRY.fetch("fake_ac").constantize.climate_entry(id: "fake:1", name: "Teste AC", manufacturer: "Teste", address: {})
      end
      stub_const("FakeAcDriver", fake)
      stub_const("Integrations::FakeAcPlugin", plugin)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS | %w[FakeAcPlugin])
      stub_const("Drivers::REGISTRY", Drivers::REGISTRY.merge("fake_ac" => "FakeAcDriver"))
      stub_const("Drivers::Climate::MAP", Drivers::Climate::MAP.merge("vendors" => { "fake_ac" => { "mode" => { "c" => "Frio" }, "fan" => { "a" => "Auto" } } }))

      add(Integrations::FakeAcPlugin, host: "10.9.9.9")
      d = site.devices.find_by!(driver: "fake_ac")
      expect(pts(d).keys).to contain_exactly("Liga/desliga", "Temperatura alvo", "Modo", "Ventilação", "Temperatura ambiente", "Clima")
      expect(pts(d)["Modo"].options).to eq([ "Frio" ])
      expect(pts(d)["Clima"]).to have_attributes(capability: "climate", writable: false)
      FakeAcDriver.poll(d)
      run(pts(d)["Liga/desliga"], "on")
      run(pts(d)["Temperatura alvo"], "set", 21.5)
      expect(pts(d)["Clima"].value).to include("power" => true, "target" => 21.5, "current" => 26.5)
      expect(ApplicationController.helpers.point_value_text(pts(d)["Clima"])).to eq("Ligado · Frio · 21,5 °C · ambiente 26,5 °C")
      expect(Alexa::SmartHome::Interfaces.for(pts(d)["Temperatura alvo"]).map(&:namespace)).to include("Alexa.ThermostatController")
    end

    describe "Daikin" do
      let(:base) { "http://10.0.0.60:80" }
      let(:control) { "ret=OK,pow=1,mode=3,stemp=24.0,shum=0,f_rate=A,f_dir=0,dt4=27.0,dh4=0,dt3=24.0,dh3=0" }

      def text(body) = { status: 200, body: body }

      before do
        stub_request(:get, "#{base}/common/basic_info").to_return(text("ret=OK,type=aircon,ver=3_3_9,mac=A0B1C2D3E4F5,name=%53%61%6c%61"))
        stub_request(:get, "#{base}/aircon/get_control_info").to_return(text(control))
        stub_request(:get, "#{base}/aircon/get_sensor_info").to_return(text("ret=OK,htemp=26.5,hhum=-,otemp=31.0"))
      end

      it "lê pela API HTTP local e grava o controle inteiro (modo traz a temperatura dele)" do
        add(Integrations::DaikinPlugin, host: "10.0.0.60")
        d = site.devices.find_by!(driver: "daikin")
        expect(d).to have_attributes(name: "Sala", external_id: "daikin:A0B1C2D3E4F5")
        p = pts(d)
        expect(p["Liga/desliga"].value).to be true
        expect(p["Modo"].value).to eq("Refrigerar")
        expect(p["Ventilação"].value).to eq("Automática")
        expect(p["Temperatura ambiente"].value).to eq(26.5)
        set = stub_request(:get, "#{base}/aircon/set_control_info").with(query: { "pow" => "1", "mode" => "4", "stemp" => "27.0", "shum" => "0", "f_rate" => "A", "f_dir" => "0" })
                                                                    .to_return(text("ret=OK"))
        run(p["Modo"], "select", "Aquecer")
        expect(set).to have_been_requested
        bad = stub_request(:get, "#{base}/aircon/set_control_info").with(query: hash_including("stemp" => "22.5")).to_return(text("ret=PARAM NG"))
        expect { run(p["Temperatura alvo"], "set", 22.5) }.not_to raise_error
        expect(bad).to have_been_requested
        expect(Command.order(:created_at).last.status).to eq("failed")
      end
    end

    describe "Midea (protocolo V3 local, aparelho de mentira em 127.0.0.1)" do
      let(:token) { SecureRandom.hex(64) }
      let(:key) { SecureRandom.hex(32) }

      # Lado do AC: aperto de mão, consulta (0xC0) e gravação (0x40).
      def fake_midea(state)
        server = TCPServer.new("127.0.0.1", 0)
        sets = Queue.new
        thread = Thread.new do
          loop do
            sock = server.accept
            k = [ key ].pack("H*")
            hello = Midea::Codec.read(sock, 2)
            raise "token errado" unless hello.byteslice(8, 64) == [ token ].pack("H*")

            plain = Random.bytes(32)
            sock.write(Midea::Codec.new.encode(Midea.aes("cbc", k, plain, encrypt: true) + Digest::SHA256.digest(plain), 1))
            codec = Midea::Codec.new(Midea.xor(plain, k))
            loop do
              raw = begin
                Midea::Codec.read(sock, 2)
              rescue Midea::Error
                break
              end
              frame = Midea.unpacket(codec.decode(raw))
              if frame.getbyte(9) == 0x02
                b = Midea.body(frame).bytes
                sets << b
                state.merge!(power: b[1].odd?, mode: b[2] >> 5, target: (b[2] & 0x0F) + 16 + (b[2].anybits?(0x10) ? 0.5 : 0), fan: b[3])
              end
              t = state[:target]
              c0 = [ 0xC0, state[:power] ? 1 : 0, (state[:mode] << 5) | (t.floor - 16) | (t % 1 >= 0.5 ? 0x10 : 0), state[:fan] ] + [ 0 ] * 7 + [ 50 + (state[:current] * 2).round ] + [ 0 ] * 10
              sock.write(codec.encode(Midea.packet(0, Midea.frame(0x03, c0.pack("C*"))), Midea::ENCRYPTED_RESPONSE))
            end
            sock.close
          end
        end
        [ server, thread, sets ]
      end

      it "aperta a mão com token e chave, lê o estado e grava o estado inteiro" do
        server, thread, sets = fake_midea({ power: false, mode: 2, target: 24.5, fan: 102, current: 27.0 })
        add(Integrations::MideaPlugin, host: "127.0.0.1", port: server.addr[1], device_id: "151732605161920", token: token, key: key)
        integration = site.integrations.find_by!(driver: "midea")
        expect(integration.secrets.keys).to contain_exactly("token", "key")
        expect(integration.settings.to_json).not_to include(token)
        d = site.devices.find_by!(driver: "midea")
        p = pts(d)
        expect([ p["Liga/desliga"].value, p["Modo"].value, p["Temperatura alvo"].value, p["Ventilação"].value, p["Temperatura ambiente"].value ])
          .to eq([ false, "Refrigerar", 24.5, "Automática", 27.0 ])
        run(p["Ventilação"], "select", "Alta")
        b = sets.pop
        expect([ b[0], b[1] & 1, b[3] ]).to eq([ 0x40, 0, 80 ])
        expect(pts(d)["Ventilação"].value).to eq("Alta")
      ensure
        thread&.kill
        server&.close
      end

      it "token ou chave inválidos viram erro de credencial (Reconfigurar)" do
        o = Integrations::MideaPlugin.setup(site, form(host: "127.0.0.1", port: 1, device_id: "1", token: "abc", key: "def"))
        expect(o.alert).to match(/inválidos/)
        expect(o.integration.reload.auth_error?).to be true
      end
    end

    describe "LG ThinQ" do
      let(:url) { "https://api-aic.lgthinq.com" }

      it "lista só os ACs da conta pelo PAT e grava o pedido sem esperar a nuvem" do
        auth = ->(req) { req.headers["Authorization"] == "Bearer pat1" && req.headers["X-Country"] == "BR" && req.headers["X-Api-Key"].present? }
        stub_request(:get, "#{url}/devices").with(&auth).to_return(json("response" => [
                                                                         { "deviceId" => "ac1", "deviceInfo" => { "deviceType" => "DEVICE_AIR_CONDITIONER", "alias" => "Ar do quarto", "modelName" => "S4-W12" } },
                                                                         { "deviceId" => "w1", "deviceInfo" => { "deviceType" => "DEVICE_WASHER", "alias" => "Lavadora" } } ]))
        stub_request(:get, "#{url}/devices/ac1/state").to_return(json("response" => {
                                                                        "operation" => { "airConOperationMode" => "POWER_ON" }, "airConJobMode" => { "currentJobMode" => "COOL" },
                                                                        "temperature" => { "currentTemperature" => 25, "targetTemperature" => 22, "unit" => "C" }, "airFlow" => { "windStrength" => "MID" } }))
        add(Integrations::LgThinqPlugin, token: "pat1")
        expect(site.devices.pluck(:name)).to eq([ "Ar do quarto" ])
        d = site.devices.find_by!(driver: "lg_thinq")
        expect(pts(d)["Ventilação"].value).to eq("Média")
        ctl = stub_request(:post, "#{url}/devices/ac1/control").with(body: { temperature: { targetTemperature: 20.0, unit: "C" } }.to_json).to_return(json("response" => {}))
        run(pts(d)["Temperatura alvo"], "set", 20)
        expect(ctl).to have_been_requested
        expect(pts(d)["Temperatura alvo"].value).to eq(20.0)
        expect(pts(d)["Clima"].value).to include("target" => 20.0, "mode" => "Refrigerar")
      end
    end
  end

  describe "solar" do
    it "SunSpec por Modbus TCP: acha o mapa, lê o modelo 103 com fatores de escala" do
      regs = Hash.new(0)
      write = ->(at, list) { list.each_with_index { |v, i| regs[at + i] = v & 0xFFFF } }
      str = ->(s, n) { (s.ljust(n * 2, "\0")).unpack("n*") }
      write.call(40_000, [ 0x5375, 0x6E53, 1, 66 ])
      write.call(40_004, str.call("Fronius", 16) + str.call("Primo 5.0", 16) + [ 0 ] * 8 + str.call("1.2", 8) + str.call("SN123", 16) + [ 1, 0 ])
      at = 40_070
      inv = Array.new(52, 0)
      inv[0], inv[1] = 103, 50
      # posição no modelo (depois do ID e do L) → valor
      { 12 => 3500, 13 => 0, 8 => 2201, 11 => -1, 14 => 6001, 15 => -2, 22 => 0x00BC, 23 => 0x614E, 24 => 0, 29 => 3700, 30 => 0, 31 => 455, 35 => -1, 36 => 4 }
        .each { |i, v| inv[i + 2] = v }
      write.call(at, inv)
      write.call(at + 52, [ 0xFFFF, 0 ])
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        loop do
          s = server.accept
          while (req = s.read(12))&.bytesize == 12
            tid, _p, _l, unit, _fn, addr, count = req.unpack("nnnCCnn")
            s.write([ tid, 0, 3 + (2 * count), unit, 3, 2 * count ].pack("nnnCCC") + Array.new(count) { |i| regs[addr + i] }.pack("n*"))
          end
          s.close
        end
      end
      add(Integrations::SunspecPlugin, host: "127.0.0.1", port: server.addr[1], unit: "1", name: "Teste Inversor")
      d = site.devices.find_by!(driver: "sunspec")
      expect(d).to have_attributes(manufacturer: "Fronius", model: "Primo 5.0", external_id: "sunspec:SN123")
      p = pts(d)
      expect(p["Potência"]).to have_attributes(value: 3500.0, unit: "W", device_class: "power")
      expect(p["Energia gerada"]).to have_attributes(value: 12_345.678, unit: "kWh", state_class: "total_increasing")
      expect([ p["Tensão CA"].value, p["Frequência"].value, p["Temperatura"].value, p["Estado"].value ]).to eq([ 220.1, 60.01, 45.5, "Gerando" ])
      expect(Dashboards::Widgets::EnergyFlowWidget.watts(p["Potência"])).to eq(3500.0)
      expect { run(p["Potência"], "set", 1) }.to raise_error(Points::Command::Error)
    ensure
      thread&.kill
      server&.close
    end

    it "Growatt: usinas da conta pelo token, potência e energia; token ruim = Reconfigurar" do
      url = "https://openapi.growatt.com/v1"
      stub_request(:get, "#{url}/plant/list").with(headers: { "token" => "gt1" })
                                             .to_return(json("error_code" => 0, "data" => { "plants" => [ { "plant_id" => 77, "name" => "Teste Usina", "peak_power" => 5.4 } ] }))
      stub_request(:get, "#{url}/plant/data?plant_id=77").to_return(json("error_code" => 0, "data" => { "current_power" => 2150.5, "today_energy" => "12.3", "total_energy" => "4567.8" }))
      add(Integrations::GrowattPlugin, token: "gt1")
      p = pts(site.devices.find_by!(external_id: "growatt:77"))
      expect([ p["Potência"].value, p["Energia hoje"].value, p["Energia total"].value ]).to eq([ 2150.5, 12.3, 4567.8 ])

      stub_request(:get, "#{url}/plant/list").with(headers: { "token" => "ruim" }).to_return(json("error_code" => 10_011, "error_msg" => "error_permission_denied"))
      o = Integrations::GrowattPlugin.setup(site, form(token: "ruim"))
      expect(o.alert).to match(/permission/)
      expect(o.integration.reload.auth_error?).to be true
    end
  end

  describe "IKEA Dirigera" do
    let(:base) { "https://10.0.0.70:8443/v1" }
    let(:devices) do
      [ { "id" => "g1", "deviceType" => "gateway", "attributes" => { "customName" => "Hub" } },
        { "id" => "l1", "deviceType" => "light", "isReachable" => true, "room" => { "name" => "Sala" },
          "attributes" => { "customName" => "Luminária", "model" => "TRADFRI bulb", "manufacturer" => "IKEA of Sweden", "isOn" => true, "lightLevel" => 60 } },
        { "id" => "b1", "deviceType" => "blinds", "attributes" => { "customName" => "Persiana", "blindsCurrentLevel" => 30, "batteryPercentage" => 88 } },
        { "id" => "s1", "deviceType" => "environmentSensor", "attributes" => { "customName" => "Vindstyrka", "currentTemperature" => 22.4, "currentRH" => 51 } } ]
    end

    it "pareia em dois passos (PKCE + botão), lista pelo mapa e comanda por PATCH" do
      authz = stub_request(:get, %r{#{base}/oauth/authorize\?.*code_challenge_method=S256}).to_return(json("code" => "c0de"))
      o = Integrations::DirigeraPlugin.setup(site, form(host: "10.0.0.70"))
      expect(o.alert).to match(/botão de ação/)
      expect(authz).to have_been_requested
      integration = o.integration
      expect(integration.secrets).to include("code" => "c0de", "verifier" => a_string_matching(/\A[\w-]{43,128}\z/))

      stub_request(:post, "#{base}/oauth/token").with(body: hash_including("code" => "c0de", "grant_type" => "authorization_code")).to_return(json("access_token" => "tok1"))
      stub_request(:get, "#{base}/devices").with(headers: { "Authorization" => "Bearer tok1" }).to_return(json(devices))
      devices.each { |dev| stub_request(:get, "#{base}/devices/#{dev['id']}").to_return(json(dev)) }
      Integrations.sync!(integration)
      expect(integration.reload.secrets).to eq("token" => "tok1")
      expect(integration.found.map { |e| e["id"] }).to contain_exactly("dirigera:l1", "dirigera:b1", "dirigera:s1")
      Integrations.adopt!(integration, integration.found.to_h { |e| [ e["id"], "" ] })

      lamp = site.devices.find_by!(external_id: "dirigera:l1")
      expect(lamp.area).to be_nil
      expect(pts(lamp)["Brilho"].value).to eq(60)
      blind = site.devices.find_by!(external_id: "dirigera:b1")
      expect([ pts(blind)["Posição"].value, pts(blind)["Bateria"].value ]).to eq([ 70.0, 88.0 ])
      expect(pts(site.devices.find_by!(external_id: "dirigera:s1"))["Umidade"].value).to eq(51.0)

      patch = stub_request(:patch, "#{base}/devices/b1").with(body: [ { attributes: { blindsTargetLevel: 0 } } ].to_json).to_return(status: 202, body: "")
      run(pts(blind)["Posição"], "set", 100)
      expect(patch).to have_been_requested
    end
  end

  describe "Sonos" do
    let(:base) { "http://10.0.0.80:1400" }

    def soap(service, action, inner)
      stub_request(:post, "#{base}/MediaRenderer/#{service}/Control").with(headers: { "SOAPACTION" => "urn:schemas-upnp-org:service:#{service}:1##{action}" })
                                                                     .to_return(status: 200, body: "<s:Envelope><s:Body><u:#{action}Response>#{inner}</u:#{action}Response></s:Body></s:Envelope>")
    end

    it "lê o que toca, volume e mudo pela UPnP e manda os comandos de mídia" do
      stub_request(:get, "#{base}/xml/device_description.xml")
        .to_return(body: "<root><device><roomName>Sala de TV</roomName><modelName>Sonos One</modelName><UDN>uuid:RINCON_ABC01400</UDN></device></root>")
      meta = CGI.escapeHTML('<DIDL-Lite><item><dc:title>Garota de Ipanema</dc:title><dc:creator>Tom Jobim</dc:creator><upnp:album>Getz/Gilberto</upnp:album></item></DIDL-Lite>')
      soap("AVTransport", "GetTransportInfo", "<CurrentTransportState>PLAYING</CurrentTransportState>")
      soap("AVTransport", "GetPositionInfo", "<TrackMetaData>#{meta}</TrackMetaData>")
      soap("RenderingControl", "GetVolume", "<CurrentVolume>25</CurrentVolume>")
      soap("RenderingControl", "GetMute", "<CurrentMute>0</CurrentMute>")
      add(Integrations::SonosPlugin, host: "10.0.0.80")
      d = site.devices.find_by!(driver: "sonos")
      expect(d).to have_attributes(name: "Sala de TV", external_id: "sonos:RINCON_ABC01400")
      media = d.points.find_by!(capability: "media")
      expect(media.value).to include("state" => "playing", "title" => "Garota de Ipanema", "artist" => "Tom Jobim", "volume" => 25, "muted" => false)
      expect(Points::Command.commands_for(media)).not_to include("on", "off")

      vol = stub_request(:post, "#{base}/MediaRenderer/RenderingControl/Control").with(body: /<DesiredVolume>40<\/DesiredVolume>/).to_return(body: "<ok/>")
      pause = soap("AVTransport", "Pause", "")
      run(media, "volume", 40)
      run(media, "pause")
      expect([ vol, pause ]).to all(have_been_requested)
    end
  end

  describe "Govee (API LAN por UDP, aparelho de mentira em 127.0.0.1)" do
    it "acha pelo scan, lê o devStatus e manda liga, brilho e cor" do
      listen = UDPSocket.new.tap { |s| s.bind("127.0.0.1", 0) }
      free = listen.addr[1]
      listen.close
      stub_const("Drivers::Govee::LISTEN_PORT", free)
      stub_const("Drivers::Govee::MULTICAST", "127.0.0.1")
      device = UDPSocket.new
      device.bind("127.0.0.1", 0)
      stub_const("Drivers::Govee::SCAN_PORT", device.addr[1])
      got = Queue.new
      state = { "onOff" => 0, "brightness" => 50, "color" => { "r" => 0, "g" => 0, "b" => 255 }, "colorTemInKelvin" => 0 }
      thread = Thread.new do
        loop do
          text, from = device.recvfrom(2048)
          msg = JSON.parse(text)["msg"]
          got << msg
          reply = ->(cmd, data) { device.send({ msg: { cmd: cmd, data: data } }.to_json, 0, from[3], free) }
          case msg["cmd"]
          when "scan" then reply.call("scan", { "ip" => "127.0.0.1", "device" => "AA:BB", "sku" => "H6159" })
          when "devStatus" then reply.call("devStatus", state)
          when "turn" then state["onOff"] = msg["data"]["value"]
          when "brightness" then state["brightness"] = msg["data"]["value"]
          when "colorwc" then state["color"] = msg["data"]["color"]
          end
        end
      end
      expect(Integrations::GoveePlugin.discover).to eq([ { "name" => "Govee H6159", "host" => "127.0.0.1", "port" => 4003, "txt" => { "device" => "AA:BB", "sku" => "H6159" } } ])

      add(Integrations::GoveePlugin, host: "127.0.0.1", port: device.addr[1], name: "Teste Fita")
      d = site.devices.find_by!(driver: "govee")
      expect(pts(d)["Luz"].value).to be false
      expect(pts(d)["Cor"].value).to include("h" => 240.0)
      run(pts(d)["Luz"], "on")
      run(pts(d)["Brilho"], "set", 80)
      run(pts(d)["Cor"], "set", "#ff0000")
      expect([ pts(d)["Luz"].value, pts(d)["Brilho"].value ]).to eq([ true, 80 ])
      expect(pts(d)["Cor"].value).to include("h" => 0.0, "s" => 100.0)
      expect(Array.new(got.size) { got.pop }.map { |m| m["cmd"] }).to include("turn", "brightness", "colorwc")
    ensure
      thread&.kill
      device&.close
    end
  end

  describe "Z-Wave JS (servidor de mentira no lugar do WebSocket)" do
    let(:state) do
      { "controller" => { "homeId" => 3_405_691_582 },
        "nodes" => [
          { "nodeId" => 1, "isControllerNode" => true, "values" => [] },
          { "nodeId" => 5, "name" => "Relé da varanda", "location" => "Varanda", "status" => 4,
            "deviceConfig" => { "manufacturer" => "Aeotec", "label" => "ZW096" },
            "values" => [
              { "commandClass" => 37, "endpoint" => 0, "property" => "currentValue", "value" => true, "metadata" => { "type" => "boolean", "readable" => true, "label" => "Current value" } },
              { "commandClass" => 37, "endpoint" => 0, "property" => "targetValue", "value" => true, "metadata" => { "type" => "boolean", "readable" => true } },
              { "commandClass" => 50, "endpoint" => 0, "property" => "value", "propertyKey" => 65_537, "value" => 12.5, "metadata" => { "label" => "Electric Consumption [kWh]", "unit" => "kWh" } },
              { "commandClass" => 50, "endpoint" => 0, "property" => "value", "propertyKey" => 66_049, "value" => 35.2, "metadata" => { "label" => "Electric Consumption [W]", "unit" => "W" } },
              { "commandClass" => 50, "endpoint" => 0, "property" => "reset", "metadata" => { "readable" => false } },
              { "commandClass" => 112, "endpoint" => 0, "property" => 3, "value" => 1, "metadata" => {} } ] },
          { "nodeId" => 6, "status" => 4, "deviceConfig" => { "manufacturer" => "Zooz", "label" => "ZSE40", "description" => "4-in-1 Sensor" },
            "values" => [
              { "commandClass" => 49, "endpoint" => 0, "property" => "Air temperature", "value" => 22.4, "metadata" => { "label" => "Air temperature", "unit" => "°C" } },
              { "commandClass" => 48, "endpoint" => 0, "property" => "Motion", "value" => false, "metadata" => { "label" => "Sensor state (Motion)" } },
              { "commandClass" => 128, "endpoint" => 0, "property" => "level", "value" => 90, "metadata" => { "unit" => "%" } } ] } ] }
    end

    it "lista os nós (sem o controlador), mapeia os valores pelo mapa e grava por node.set_value" do
      sent = []
      inbox = []
      ws = instance_double(WsClient, close: nil, closed?: false)
      allow(ws).to receive(:connect) do
        inbox << { "type" => "version", "maxSchemaVersion" => 40 }
        ws
      end
      allow(ws).to receive(:read_json) { inbox.shift }
      allow(ws).to receive(:send_json) do |msg|
        sent << msg
        inbox << { "type" => "event", "event" => { "source" => "node" } }
        inbox << { "type" => "result", "messageId" => msg["messageId"], "success" => true, "result" => msg["command"] == "start_listening" ? { "state" => state } : {} }
      end
      allow(WsClient).to receive(:new).and_return(ws)

      add(Integrations::ZwaveJsPlugin, url: "ws://10.0.0.90:3000")
      expect(sent.first).to include("command" => "set_api_schema", "schemaVersion" => 35)
      expect(site.devices.pluck(:external_id)).to contain_exactly("zwave:3405691582:5", "zwave:3405691582:6")
      relay = site.devices.find_by!(external_id: "zwave:3405691582:5")
      expect(relay.area).to be_nil
      p = pts(relay)
      expect(p.keys).to contain_exactly("Liga/desliga", "Electric Consumption [kWh]", "Electric Consumption [W]")
      expect(p["Electric Consumption [kWh]"]).to have_attributes(value: 12.5, device_class: "energy", state_class: "total_increasing")
      sensor = pts(site.devices.find_by!(external_id: "zwave:3405691582:6"))
      expect(sensor["Sensor state (Motion)"]).to have_attributes(capability: "motion", value: false)
      expect(sensor["Bateria"].value).to eq(90.0)
      expect(sensor["Air temperature"]).to have_attributes(value: 22.4, device_class: "temperature")

      run(p["Liga/desliga"], "off")
      set = sent.find { |m| m["command"] == "node.set_value" }
      expect(set).to include("nodeId" => 5, "value" => false, "valueId" => { "commandClass" => 37, "endpoint" => 0, "property" => "targetValue" })
      expect(p["Liga/desliga"].reload.value).to be false
    end
  end

  describe "proxy Bluetooth (ESPHome)" do
    def ad(type, bytes) = [ bytes.size + 1, type, *bytes ].pack("C*")
    let(:bthome) { ad(0x09, "Teste BT".bytes) + ad(0x16, [ 0xD2, 0xFC, 0x40, 0x02, 0xCA, 0x09, 0x03, 0xBF, 0x13, 0x01, 0x5D ]) }
    let(:pvvx) { ad(0x16, [ 0x1A, 0x18 ] + [ 1, 2, 3, 4, 5, 6 ] + [ 2150, 4520, 2950 ].pack("s<S<S<").bytes + [ 87, 9, 0 ]) }
    let(:govee) { ad(0xFF, [ 0x88, 0xEC, 0x00, 0x03, 0x97, 0xC0, 0x64, 0x00 ]) }

    it "decodifica BTHome, pvvx e Govee e ignora o cifrado" do
      expect(Ble.decode(bthome)).to eq([ "Teste BT", { "temperature" => 25.06, "humidity" => 50.55, "battery" => 93 } ])
      expect(Ble.decode(pvvx)[1]).to eq("temperature" => 21.5, "humidity" => 45.2, "voltage" => 2.95, "battery" => 87)
      expect(Ble.decode(govee)[1]).to eq("temperature" => 23.5, "humidity" => 45.6, "battery" => 100)
      expect(Ble.decode(ad(0x16, [ 0xD2, 0xFC, 0x41, 0x02, 0xCA, 0x09 ]))).to be_nil
      expect(Ble.decode("\x02\x01\x06".b)).to be_nil
    end

    it "assina os anúncios crus, lista os sensores e lê pelo proxy" do
      adv = ->(mac, data) { Proto.encode([ [ 1, :varint, mac ], [ 2, :sint, -60 ], [ 4, :bytes, data ] ]) }
      batch = Proto.encode([ [ 1, :message, adv.call(0xA4C138000001, bthome) ], [ 1, :message, adv.call(0xA4C138000002, govee) ],
                             [ 1, :message, adv.call(0xA4C138000003, ad(0x09, "Fone".bytes)) ] ])
      client = instance_double(Esphome::Client)
      subscribed = []
      allow(client).to receive(:send_message) { |type, fields| subscribed << [ type, fields ] }
      allow(client).to receive(:read) { subscribed.shift ? [ 93, Proto.decode(batch) ] : nil } # um lote por assinatura
      allow(Esphome::Client).to receive(:open) { |**_kw, &blk| blk.call(client) }

      add(Integrations::BleProxyPlugin, host: "10.0.0.95", encryption_key: "a2V5")
      expect(site.devices.order(:external_id).pluck(:external_id, :name)).to eq([ [ "A4:C1:38:00:00:01", "Teste BT 00:01" ], [ "A4:C1:38:00:00:02", "Govee 00:02" ] ])
      t = site.devices.find_by!(external_id: "A4:C1:38:00:00:02")
      expect(pts(t)["Temperatura"]).to have_attributes(value: 23.5, unit: "°C", device_class: "temperature")
      expect(pts(t)["Umidade"].value).to eq(45.6)
      expect(site.integrations.find_by!(driver: "ble_proxy").secrets).to eq("encryption_key" => "a2V5")
    end
  end
end
