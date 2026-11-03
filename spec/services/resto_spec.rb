require "rails_helper"

# resto (paridade, 2026-11-03): o que faltava nos grupos 3, 5, 7 e 9. Tudo
# por registro, com plugin falso por stub_const; nada de rede, conta ou aparelho real.
RSpec.describe "Paridade: resto" do
  let(:tenant) { create(:tenant) }
  let!(:site) { ActsAsTenant.with_tenant(tenant) { create(:site, latitude: -23.55, longitude: -46.63) } }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  describe "MQTT: componentes da descoberta do HA que faltavam (5.10)" do
    let(:disc) { Mqtt::HaDiscovery }

    def config(topic, payload) = disc.handle("homeassistant/#{topic}/config", payload.to_json)
    def pts(id) = site.devices.find_by!(external_id: "mqtt-ha:#{id}").points.reload.index_by { |p| p.address["discovery"] }

    before { allow(Mqtt::Listener).to receive(:publish) }

    it "alarme (crítico), aspirador com comandos pelo nome, cortador, umidificador, aquecedor e firmware" do
      dev = ->(id) { { "ids" => [ id ], "name" => "Teste #{id}" } }
      config("alarm_control_panel/a1", "uniq_id" => "a1", "stat_t" => "casa/alarme", "cmd_t" => "casa/alarme/set", "pl_arm_away" => "FORA", "dev" => dev.call("a1"))
      alarm = pts("a1").values.sole
      expect(alarm).to have_attributes(capability: "enum", risk: "critical")
      Mqtt::Listener.handle("casa/alarme", "armed_home")
      expect(alarm.reload.value).to eq("armed_home")
      expect(Drivers::Mqtt.payload(alarm, "armed_away")).to eq("FORA")
      expect(Drivers::Mqtt.payload(alarm, "disarmed")).to eq("DISARM")

      config("vacuum/v1", "uniq_id" => "v1", "stat_t" => "robo/state", "cmd_t" => "robo/cmd", "set_fan_spd_t" => "robo/fan", "fanspd_lst" => %w[min max],
                          "pl_ret" => "base", "dev" => dev.call("v1"))
      v = pts("v1")
      robo = v.values.find { |p| p.capability == "vacuum" }
      Mqtt::Listener.handle("robo/state", '{"state":"cleaning","fan_speed":"max","battery_level":61}')
      expect([ robo.reload.value, v.values.find { |p| p.name == "Bateria" }.reload.value ]).to eq([ "cleaning", 61 ])
      ExecuteCommandJob.perform_now(Points::Command.call(robo, "home", source: "web").id)
      expect(Mqtt::Listener).to have_received(:publish).with("robo/cmd", "base")

      config("lawn_mower/m1", "uniq_id" => "m1", "activity_state_topic" => "cortador/atividade", "dock_command_topic" => "cortador/base", "dev" => dev.call("m1"))
      expect(pts("m1").values.map(&:capability)).to contain_exactly("enum", "command")

      config("humidifier/h1", "uniq_id" => "h1", "cmd_t" => "umid/set", "stat_t" => "umid/state", "hum_cmd_t" => "umid/alvo", "curr_hum_t" => "umid/atual", "dev" => dev.call("h1"))
      expect(pts("h1").values.map(&:capability)).to contain_exactly("onoff", "setpoint", "measure")

      config("water_heater/w1", "uniq_id" => "w1", "mode_cmd_t" => "boiler/modo", "temp_cmd_t" => "boiler/alvo", "curr_temp_t" => "boiler/agua", "dev" => dev.call("w1"))
      expect(pts("w1").values.map(&:capability)).to contain_exactly("enum", "setpoint", "measure")

      config("update/u1", "uniq_id" => "u1", "stat_t" => "placa/fw", "cmd_t" => "placa/fw/set", "dev" => dev.call("u1"))
      fw = pts("u1").values.sole
      Mqtt::Listener.handle("placa/fw", '{"installed_version":"1.0","latest_version":"1.1"}')
      expect(Firmware.available?(fw.reload)).to be true
      Mqtt::Listener.handle("placa/fw", "1.1")
      expect(Firmware.view(fw.reload.value)).to include(installed: "1.1", state: "up_to_date")
      expect(Firmware.provider(fw.device)).to eq(Firmware::Providers::MqttDiscovery)
      Firmware.install!(fw, user: nil)
      expect(Mqtt::Listener).to have_received(:publish).with("placa/fw/set", "install")
    end

    it "câmera MQTT: a imagem do tópico vira o quadro do ponto" do
      config("camera/c1", "uniq_id" => "c1", "t" => "cam/quintal/jpg", "dev" => { "ids" => [ "c1" ], "name" => "Teste Câmera" })
      cam = pts("c1").values.sole
      expect(cam.capability).to eq("stream")
      jpeg = "\xFF\xD8teste\xFF\xD9".b
      Mqtt::Listener.handle("cam/quintal/jpg", jpeg)
      expect(cam.reload.value).to be_present
      expect(Drivers::Go2rtc.snapshot(cam)).to eq(jpeg)
    end
  end

  describe "Firmware: Tasmota e ESPHome (7.22) e provedor falso" do
    it "Tasmota compara com a versão publicada e instala pelo Upgrade" do
      stub_request(:get, Firmware::Providers::Tasmota::RELEASES).to_return(body: { tag_name: "v14.2.0" }.to_json)
      allow(SafeHttp).to receive(:lookup).and_return([ "140.82.112.6" ])
      d = create(:device, site: site, driver: "mqtt", manufacturer: "Tasmota", name: "Teste Tomada", firmware: "13.1.0(tasmota)", address: { "cmnd" => "cmnd/tomada/" })
      allow(Mqtt::Listener).to receive(:publish)
      Rails.cache.delete("firmware/tasmota/latest")
      point = Firmware.check!(d)
      expect(Firmware.view(point.value)).to include(installed: "13.1.0", latest: "14.2.0", state: "available")
      Firmware.install!(point, user: nil)
      expect(Mqtt::Listener).to have_received(:publish).with("cmnd/tomada/Upgrade", "1")
    end

    it "ESPHome pergunta ao painel do app ESPHome" do
      stub_const("ENV", ENV.to_h.merge("ESPHOME_DASHBOARD_URL" => "http://127.0.0.1:6052"))
      stub_request(:get, "http://127.0.0.1:6052/devices").to_return(body: { configured: [
        { name: "teste-placa", address: "10.0.0.40", configuration: "teste-placa.yaml", deployed_version: "2025.1.0", current_version: "2025.2.0" }
      ] }.to_json)
      d = create(:device, site: site, driver: "esphome", name: "Teste Placa", address: { "host" => "10.0.0.40" })
      point = Firmware.check!(d)
      expect(Firmware.view(point.value)).to include(installed: "2025.1.0", latest: "2025.2.0", state: "available")
    end

    it "provedor novo entra pelo registro sem mudar o núcleo" do
      fake = Class.new(Firmware::Provider) do
        describe key: "teste"
        def self.handles?(device) = device.name == "Teste FW"
        def self.check(_device) = { installed: "1", latest: "2" }
      end
      stub_const("Firmware::Providers::Teste", fake)
      stub_const("Firmware::PROVIDERS", [ "Teste" ] + Firmware::PROVIDERS)
      expect(Firmware.available?(Firmware.check!(create(:device, site: site, name: "Teste FW")))).to be true
    end
  end

  describe "ONVIF: os outros eventos das câmeras (grupo 9, #54)" do
    def message(topic, item, value) = %(<wsnt:NotificationMessage xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2" xmlns:tt="http://www.onvif.org/ver10/schema"><wsnt:Topic>#{topic}</wsnt:Topic><wsnt:Message><tt:Message><tt:Data><tt:SimpleItem Name="#{item}" Value="#{value}"/></tt:Data></tt:Message></wsnt:Message></wsnt:NotificationMessage>)

    def doc(*msgs) = REXML::Document.new("<r>#{msgs.join}</r>")

    it "lê movimento, violação, linha, invasão, pessoa e entrada digital; o resto fica de fora" do
      d = doc(message("tns1:RuleEngine/CellMotionDetector/Motion", "IsMotion", "true"), message("tns1:VideoSource/GlobalSceneChange/ImagingService", "State", "true"),
              message("tns1:RuleEngine/LineDetector/Crossed", "State", "true"), message("tns1:RuleEngine/FieldDetector/ObjectsInside", "IsInside", "false"),
              message("tns1:RuleEngine/MyRuleDetector/PeopleDetect", "State", "1"), message("tns1:Device/Trigger/DigitalInput", "LogicalState", "true"),
              message("tns1:Monitoring/ProcessorUsage", "Value", "37"))
      expect(Onvif.events(d)).to eq([ %w[motion] + [ true ], [ "tamper", true ], [ "line", true ], [ "field", false ], [ "person", true ], [ "input", true ] ])
      expect(Onvif.motions(d)).to eq([ true ])
      names = Onvif.event_points("RuleEngine/CellMotionDetector/Motion/LineDetector/Crossed/Device/Trigger/DigitalInput").map { |p| p["address"]["onvif"] }
      expect(names).to eq(%w[line input])
    end

    it "evento novo entra pelo registro e o ouvinte passa cada um ao seu ponto" do
      stub_const("Onvif::EVENTS", [ Onvif::Event.new("doorbell", /Doorbell/i, %w[State], "event", nil) ] + Onvif::EVENTS)
      expect(Onvif.events(doc(message("tns1:Device/Doorbell/Pressed", "State", "true")))).to eq([ [ "doorbell", true ] ])

      cam = create(:device, site: site, name: "Teste Cam", driver: "go2rtc", address: { "host" => "10.0.0.20" })
      line = create(:point, device: cam, site: site, name: "Linha", capability: "motion", address: { "onvif" => "line" })
      motion = create(:point, device: cam, site: site, name: "Movimento", capability: "motion", address: { "onvif" => "motion" })
      expect(Onvif::Listener.motion_points.pluck(:id)).to contain_exactly(line.id, motion.id)
      Onvif::Listener.report(cam.id, true, key: "line")
      expect([ line.reload.value, motion.reload.value ]).to eq([ true, nil ])
    end
  end

  describe "Sistema: uptime, placa e fonte do Raspberry Pi (grupo 9, #15, #27, #74)" do
    it "lê a placa, a subtensão do rpi_volt e quando o servidor ligou" do
      Dir.mktmpdir do |sys|
        expect([ Integrations::SystemPlugin.board(sys), Integrations::SystemPlugin.undervoltage(sys) ]).to eq([ nil, nil ])
        FileUtils.mkdir_p("#{sys}/firmware/devicetree/base")
        File.write("#{sys}/firmware/devicetree/base/model", "Raspberry Pi 5 Model B Rev 1.0\0")
        FileUtils.mkdir_p("#{sys}/class/hwmon/hwmon0")
        File.write("#{sys}/class/hwmon/hwmon0/name", "rpi_volt\n")
        File.write("#{sys}/class/hwmon/hwmon0/in0_lcrit_alarm", "1\n")
        expect([ Integrations::SystemPlugin.board(sys), Integrations::SystemPlugin.undervoltage(sys) ]).to eq([ "Raspberry Pi 5 Model B Rev 1.0", true ])
        File.write("#{sys}/uptime", "3600.5 100.0")
        expect(Integrations::SystemPlugin.booted_at("#{sys}/uptime")).to be_within(61).of(1.hour.ago)
      end
      integration = site.integrations.create!(driver: "system", name: "Sistema")
      Integrations::SystemPlugin.sync!(integration)
      keys = Integrations::SystemPlugin.device_for(integration).points.map { |p| p.address["field"] }
      expect(keys).to include("app_up_since")
    end
  end

  describe "Helper Proximidade (grupo 9, #73)" do
    it "distância até a zona e a direção, com tolerância" do
      home = HelperTypes::Zone.home(site)
      phone = create(:point, site: site, device: create(:device, site: site, name: "Teste Celular"), name: "Local", capability: "text",
                             attrs: { "latitude" => -23.60, "longitude" => -46.63 })
      prox = HelperTypes.build(site, HelperTypes.plugin("proximity"))
      expect(HelperTypes.save(prox, "name" => "Teste Proximidade", "source" => phone.id, "zone" => home.id, "tolerance_m" => "50", "unit" => "km")).to be true
      expect(prox.reload.value).to be_within(0.2).of(5.4)
      phone.report_attrs!("latitude" => -23.58, "longitude" => -46.63)
      expect(prox.reload.attrs["direction"]).to eq("towards")
      phone.report_attrs!("latitude" => -23.5801, "longitude" => -46.63)
      expect(prox.reload.attrs["direction"]).to eq("stationary")
      phone.report_attrs!("latitude" => -23.62, "longitude" => -46.63)
      expect(prox.reload.attrs["direction"]).to eq("away_from")
      phone.report_attrs!("latitude" => -23.55, "longitude" => -46.63)
      expect(prox.reload).to have_attributes(value: 0)
      expect(prox.attrs).to include("direction" => "arrived", "in_zone" => true)
      expect(HelperTypes.save(HelperTypes.build(site, HelperTypes.plugin("proximity")), "name" => "Teste Sem", "source" => home.id, "zone" => home.id)).to be false
    end
  end

  describe "Brother por SNMP (grupo 9, #38)" do
    # Impressora de mentira em 127.0.0.1: lê o GET (BER) e responde com a tabela.
    def snmp_printer(table)
      sock = UDPSocket.new
      sock.bind("127.0.0.1", 0)
      Thread.new do
        loop do
          data, from = sock.recvfrom(2048)
          _, msg, = Snmp.read(data)
          (_, _), (_, community), (_, pdu) = Snmp.items(msg)
          (_, rid), _, _, (_, binds) = Snmp.items(pdu)
          oids = Snmp.items(binds).map { |_, b| Snmp.decode_oid(Snmp.items(b).first[1]) }
          vals = oids.map do |o|
            v = community == "public" ? table[o] : nil
            body = case v
            when Integer then o == Integrations::BrotherPlugin::PAGES ? Snmp.tlv(0x41, Snmp.int_bytes(v)) : Snmp.int(v)
            when String then Snmp.tlv(0x04, v.b)
            else Snmp.tlv(0x81, "")
            end
            Snmp.tlv(0x30, Snmp.oid(o) + body)
          end
          reply = Snmp.tlv(0x30, Snmp.int(1) + Snmp.tlv(0x04, community) + Snmp.tlv(0xA2, Snmp.tlv(0x02, rid) + Snmp.int(0) + Snmp.int(0) + Snmp.tlv(0x30, vals.join)))
          sock.send(reply, 0, from[3], from[1])
        end
      rescue IOError
        nil
      end
      [ sock, sock.addr[1] ]
    end

    it "estado, páginas e cada suprimento com o nome da impressora; nível -3 vira 'pouco'" do
      s = Integrations::BrotherPlugin::SUPPLY
      sock, port = snmp_printer(Integrations::BrotherPlugin::SYS_DESCR => "Brother HL-L2350DW series", Integrations::BrotherPlugin::SERIAL => "E7X1",
                                Integrations::BrotherPlugin::PAGES => 123_456, Integrations::BrotherPlugin::STATUS => 3,
                                "#{s}.6.1.1" => "Toner Cartridge", "#{s}.8.1.1" => 2600, "#{s}.9.1.1" => 650,
                                "#{s}.6.1.2" => "Drum Unit", "#{s}.8.1.2" => 12_000, "#{s}.9.1.2" => -3)
      expect(Snmp.get("127.0.0.1", [ Integrations::BrotherPlugin::PAGES, "1.3.6.1.9.9" ], port: port)).to eq(Integrations::BrotherPlugin::PAGES => 123_456)
      allow(Snmp).to receive(:get).and_wrap_original { |m, host, oids, **kw| m.call(host, oids, **kw, port: port) }

      o = Integrations::BrotherPlugin.setup(site, ActionController::Parameters.new(host: "127.0.0.1"))
      expect(o.alert).to be_nil
      i = o.integration
      entry = i.found.sole
      expect(entry).to include("id" => "brother:E7X1", "name" => "Brother HL-L2350DW series")
      Integrations.adopt!(i, entry["id"] => "")
      d = i.devices.sole
      Integrations::BrotherPlugin.poll(d)
      v = d.points.reload.to_h { |p| [ p.name, p.value ] }
      expect(v).to include("Páginas impressas" => 123_456, "Estado" => "pronta", "Toner Cartridge restante" => 25, "Drum Unit restante" => 10)
    ensure
      sock&.close
    end
  end

  describe "câmeras de nuvem: Ring, Nest e Netatmo (grupo 9, #46, #68, #75)" do
    def cloud(driver, secrets = {}, settings = {})
      site.integrations.create!(driver: driver, name: "Teste #{driver}", settings: settings, credentials: secrets.to_json)
    end

    def stream(plugin, integration, address)
      d = create(:device, site: site, driver: plugin.driver, name: "Teste Câmera", integration: integration, address: address)
      create(:point, site: site, device: d, name: "Vídeo", key: "teste.video_#{SecureRandom.hex(3)}", capability: "stream", address: { "on_demand" => true, "field" => "video" })
    end

    before { allow(Integrations::RingPlugin).to receive(:access_token).and_return("x") }

    it "cada uma vira um ponto de vídeo sob demanda que o go2rtc abre pela fonte certa" do
      ring = stream(Integrations::RingPlugin, cloud("ring", "refresh_token" => "rt/1"), { "id" => "987" })
      expect(Drivers::Go2rtc.source(ring)).to eq("ring:?refresh_token=rt%2F1&device_id=987")

      allow(Integrations::NestPlugin).to receive(:access_token).and_return("x")
      nest_i = cloud("nest", { "refresh_token" => "nrt", "client_secret" => "cs" }, { "client_id" => "cid", "project_id" => "proj" })
      cam = Integrations::NestPlugin.camera_entry("name" => "enterprises/proj/devices/DEV1", "type" => "sdm.devices.types.DOORBELL",
                                                  "traits" => { "sdm.devices.traits.Info" => { "customName" => "Teste Porta" } })
      expect(cam).to include("name" => "Teste Porta", "model" => "Doorbell")
      expect(cam["points"].sole).to include("capability" => "stream", "address" => { "on_demand" => true, "field" => "video" })
      nest = stream(Integrations::NestPlugin, nest_i, { "name" => "enterprises/proj/devices/DEV1", "camera" => true })
      expect(Drivers::Go2rtc.source(nest)).to eq("nest:?client_id=cid&client_secret=cs&refresh_token=nrt&project_id=proj&device_id=DEV1")

      net_i = cloud("netatmo")
      allow(Integrations::NetatmoPlugin).to receive(:api) do |_i, _m, url|
        url.include?("homesdata") ? { "body" => { "homes" => [ { "id" => "h1", "modules" => [ { "id" => "70:ee:50", "type" => "NOC", "name" => "Teste Quintal" } ] } ] } }
                                  : { "body" => { "home" => { "modules" => [ { "id" => "70:ee:50", "vpn_url" => "https://vpn.netatmo.net/abc", "monitoring" => "on" } ] } } }
      end
      expect(Integrations::NetatmoPlugin.cameras(net_i).sole).to include("name" => "Teste Quintal", "monitoring" => "on")
      net = stream(Integrations::NetatmoPlugin, net_i, { "home" => "h1", "camera" => "70:ee:50" })
      expect(Drivers::Go2rtc.source(net)).to eq("ffmpeg:https://vpn.netatmo.net/abc/live/files/high/index.m3u8#video=copy")
    end
  end
end

