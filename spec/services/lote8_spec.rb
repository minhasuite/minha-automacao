require "rails_helper"

# Lote 8 (recursos genéricos que faltavam para a migração): cor de lâmpada
# pelo mapa de dados, gatilho por atributo, "Comandar pontos por consulta",
# eventos do robô deduzidos da leitura, som/música/volume na Echo e o
# importador do HA usando tudo isso. Tudo sintético; nada sai para a rede.
RSpec.describe "Lote 8: recursos genéricos da migração" do
  include ActiveJob::TestHelper

  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, name: "Local") }
  let(:device) { create(:device, site: site, driver: "virtual", name: "Aparelho") }
  let(:tuya_color) do
    { "hs" => { "format" => "hsv_json", "via" => { "tuya_local" => "hsv_hex" }, "s_max" => 1000, "v_max" => 1000 },
      "temp" => { "code" => "temp_value_v2", "dps" => "23", "raw_min" => 0, "raw_max" => 1000, "min_k" => 2000, "max_k" => 6500 },
      "mode" => { "code" => "work_mode", "dps" => "21", "hs" => "colour", "temp" => "white" } }
  end

  around { |ex| ActsAsTenant.with_tenant(tenant) { travel_to(Time.zone.parse("2026-10-31 12:00")) { ex.run } } }

  def point(name, key, capability: "onoff", dev: device, **attrs)
    create(:point, site: site, device: dev, name: name, key: key, capability: capability, data_type: Point::CAPABILITIES[capability], writable: true, **attrs)
  end

  def run!(actions, shadow: false)
    a = Automation.create!(site: site, name: "A #{SecureRandom.hex(3)}", kind: "automation", mode: "parallel", shadow: shadow)
    a.publish!({ "triggers" => [ { "type" => "manual" } ], "conditions" => [], "actions" => actions })
    a.fire!({ "type" => "manual", "title" => "Teste" }, skip_conditions: true)
  end


  describe "cor de lâmpada (Points::Color)" do
    it "aceita hs, rgb, #hex, kelvin e mireds e recusa o que não serve" do
      p = point("Cor", "cor", capability: "color")
      norm = ->(v) { Points::Command.new(p, "set", v).new_value }
      expect(norm.call({ "rgb" => [ 71, 69, 161 ] })).to eq("mode" => "hs", "h" => 241.3, "s" => 57.1)
      expect(norm.call("#ff0000")).to eq("mode" => "hs", "h" => 0.0, "s" => 100.0)
      expect(norm.call({ "hs" => [ 400, 150 ], "v" => 30 })).to eq("mode" => "hs", "h" => 40.0, "s" => 100.0, "v" => 30)
      expect(norm.call({ "h" => "120", "s" => "50,5" })).to include("h" => 120.0, "s" => 50.5)
      expect(norm.call({ "kelvin" => 3000 })).to eq("mode" => "temp", "kelvin" => 3000)
      expect(norm.call({ "mireds" => 250 })).to eq("mode" => "temp", "kelvin" => 4000)
      [ {}, "azul", { "rgb" => [ 1, 2 ] }, { "hs" => [ "x", 1 ] }, { "mireds" => 0 } ].each do |bad|
        expect { norm.call(bad) }.to raise_error(Points::Command::Error), bad.inspect
      end
      sem_temp = point("Só cor", "so_cor", capability: "color", address: { "color" => { "hs" => { "format" => "rgb_int" } } })
      expect { Points::Command.new(sem_temp, "set", { "kelvin" => 3000 }).new_value }.to raise_error(Points::Command::Error, /não aceita temperatura/)
      expect(Points::Color.hex_of({ "mode" => "hs", "h" => 0, "s" => 100 })).to eq("#ff0000")
      expect(Points::Color.hex_of(nil)).to eq("#ffffff")
    end

    it "varredura da Tuya: o dp da cor vira ponto com os irmãos (modo; temperatura que o aparelho não tem sai)" do
      rel = [ { "statusCode" => "switch_led", "dpId" => 20, "valueType" => "Boolean" },
              { "statusCode" => "bright_value_v2", "dpId" => 22, "valueType" => "Integer", "valueDesc" => '{"min":10,"max":1000,"scale":0}' },
              { "statusCode" => "work_mode", "dpId" => 21, "valueType" => "Enum", "valueDesc" => '{"range":["white","colour"]}' },
              { "statusCode" => "colour_data_v2", "dpId" => 24, "valueType" => "Json", "valueDesc" => "{}" } ]
      specs = Tuya::Cloud.points("Lâmpada", rel, %w[switch_led bright_value_v2 work_mode colour_data_v2])
      cor = specs.find { |s| s["capability"] == "color" }
      expect(cor).to include("name" => "Cor", "writable" => true)
      expect(cor["address"]).to include("dps" => "24", "code" => "colour_data_v2")
      expect(cor["address"]["color"].keys).to eq(%w[hs mode])
      expect(cor["address"]["color"]["mode"]).to include("dps" => "21", "code" => "work_mode")
    end

    it "Tuya local grava modo e cor num pedido só; a nuvem manda os códigos; o retorno do dp vira cor" do
      lamp = create(:device, site: site, driver: "tuya_local", name: "Lâmpada", external_id: "dev1", address: { "host" => "10.0.0.9" }, credential: "k" * 16)
      create(:point, site: site, device: lamp, name: "Brilho", key: "lamp.brilho", capability: "dimmer", data_type: "integer", writable: true, value: 50, address: { "dps" => "22" })
      cor = create(:point, site: site, device: lamp, name: "Cor", key: "lamp.cor", capability: "color", data_type: "json", writable: true,
                           address: { "dps" => "24", "code" => "colour_data_v2", "color" => tuya_color })
      conn = instance_double(Tuya::Connection, set: {}, close: nil)
      allow(conn).to receive_messages(connect: conn, status: { "24" => "00f001f401f4" }) # a LAN responde em hex
      allow(Drivers::TuyaLocal).to receive(:connection_for).and_return(conn)
      Drivers::TuyaLocal.new.execute(cor, "set", { "hs" => [ 240, 50 ] })
      expect(conn).to have_received(:set).with("21" => "colour", "24" => "00f001f401f4")
      expect(cor.reload.value).to eq("mode" => "hs", "h" => 240.0, "s" => 50.0, "v" => 50)

      Drivers::TuyaLocal.new.execute(cor, "set", { "kelvin" => 4250 })
      expect(conn).to have_received(:set).with("21" => "white", "23" => 500)

      cloud = instance_double(Tuya::Cloud, commands: true)
      allow(Drivers::TuyaCloud).to receive(:cloud_for).and_return(cloud)
      Drivers::TuyaCloud.new.execute(cor, "set", { "kelvin" => 2000 })
      expect(cloud).to have_received(:commands).with("dev1", [ { "code" => "work_mode", "value" => "white" }, { "code" => "temp_value_v2", "value" => 0 } ])
      expect(cor.reload.value).to eq("mode" => "temp", "kelvin" => 2000)
    end

    it "Xiaomi: a propriedade da cor (RGB inteiro) e a temperatura irmã do mapa miot.yml" do
      service = { "iid" => 2, "properties" => [ { "iid" => 4, "type" => "urn:miot-spec-v2:property:color:x" },
                                                { "iid" => 5, "type" => "urn:miot-spec-v2:property:color-temperature:x" } ] }
      conf = Miio::Spec.color_siblings(Miio::Spec::PROPS["color"]["color"], service)
      expect(conf).to eq("hs" => { "format" => "rgb_int" }, "temp" => { "siid" => 2, "piid" => 5 })
      expect(Miio::Spec.color_siblings({ "temp" => { "property" => "nada" } }, service)).to eq({})

      lamp = create(:device, site: site, driver: "xiaomi_miot", name: "Abajur", address: { "host" => "10.0.0.8" }, credential: "a" * 32)
      cor = create(:point, site: site, device: lamp, name: "Cor", key: "abajur.cor", capability: "color", data_type: "json", writable: true,
                           address: { "siid" => 2, "piid" => 4, "color" => conf })
      client = double("miio", get_properties: { [ 2, 4 ] => 0xFF0000 }) # rubocop:disable RSpec/VerifiedDoubles
      allow(client).to receive(:set_properties)
      Drivers::XiaomiMiot.new(client: client).execute(cor, "set", "#ff0000")
      expect(client).to have_received(:set_properties).with([ [ [ 2, 4 ], 0xFF0000 ] ])
      Drivers::XiaomiMiot.new(client: client).execute(cor, "set", { "kelvin" => 3500 })
      expect(client).to have_received(:set_properties).with([ [ [ 2, 5 ], 3500 ] ])
      expect(cor.reload.value).to eq("mode" => "hs", "h" => 0.0, "s" => 100.0)
    end

    it "formato novo de cor é só uma linha em FORMATS (plugin falso por stub_const)" do
      stub_const("Points::Color::FORMATS", Points::Color::FORMATS.merge("csv" => [ ->(c, _f) { "#{c['h'].round},#{c['s'].round}" }, ->(raw, _f) { Points::Color.hs(*raw.split(",")) } ]))
      p = point("Cor", "cor_csv", capability: "color", address: { "x" => 1, "color" => { "hs" => { "format" => "csv" } } })
      v = Points::Command.new(p, "set", { "hs" => [ 10, 20 ] }).new_value
      expect(p.raw_writes(v)).to eq([ [ { "x" => 1 }, "10,20" ] ])
      expect(p.from_raw("30,40")).to eq("mode" => "hs", "h" => 30.0, "s" => 40.0)
    end
  end

  describe "gatilho por atributo" do
    it "dispara quando o atributo muda (Point#report_attrs!) e não pelo valor" do
      echo = point("Echo", "echo", attrs: {})
      a = Automation.create!(site: site, name: "Atributo", kind: "automation", mode: "parallel")
      a.publish!({ "triggers" => [ { "type" => "state", "point" => echo.id, "attribute" => "last_called", "to" => "sim" } ], "conditions" => [], "actions" => [ { "type" => "trace_note", "message" => "oi" } ] })
      a.update!(enabled: true)
      expect { echo.report!(true) }.not_to(change { a.runs.count })
      expect { echo.report_attrs!("last_called" => "não") }.not_to(change { a.runs.count })
      expect { echo.report_attrs!("last_called" => "sim") }.to change { a.runs.count }.by(1)
      expect { echo.report_attrs!("last_called" => "sim") }.not_to(change { a.runs.count })
      expect(Automations::Dsl.errors({ "triggers" => [ { "type" => "state", "point" => echo.id, "attribute" => "x", "for" => "1m" } ], "actions" => [] }, site))
        .to include(a_string_including("não vale com atributo"))
    end
  end

  describe "Comandar pontos por consulta (G8)" do
    let!(:luz1) { point("Luz 1", "luz1", value: true).tap { |p| Tagging.create!(tag: Tag.find_or_create_by!(name: "iluminação"), taggable: p) } }
    let!(:luz2) { point("Luz 2", "luz2", value: false).tap { |p| Tagging.create!(tag: Tag.find_or_create_by!(name: "iluminação"), taggable: p) } }
    let!(:sensor) { point("Porta", "porta", capability: "contact", value: true, writable: false) }

    it "comanda só os pontos da consulta que aceitam o comando" do
      run = run!([ { "type" => "command_query", "query" => "tag=iluminação state=on", "command" => "off" } ])
      expect(run.status).to eq("done")
      expect(Command.pluck(:point_id, :command)).to eq([ [ luz1.id, "off" ] ])
      expect(run.steps.pluck("title")).to include(a_string_including("1 ponto"))
      a = Automation.last
      expect(Automations::ActionTypes::CommandQueryAction.commanded_point_ids(a.definition["actions"][0], site, [])).to eq([])
      expect(Automations::ActionTypes::CommandQueryAction.commanded_point_ids({ "query" => "tag=iluminação", "command" => "on" }, site, [])).to contain_exactly(luz1.id, luz2.id)
      expect(Automations::Dsl.errors({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "command_query", "query" => "cor=azul", "command" => "off" } ] }, site))
        .to include(a_string_including("filtro desconhecido"))
    end

    it "em sombra fica no \"teria feito\" com os pontos, sem comando" do
      run = run!([ { "type" => "command_query", "query" => "{{ 'tag=iluminação' }}", "command" => "on" } ], shadow: true)
      expect(run.status).to eq("done")
      expect(Command.count).to eq(0)
      expect(ShadowAction.last.effects.pluck("point_id")).to contain_exactly(luz1.id, luz2.id)
    end
  end

  describe "eventos do robô (miot.yml)" do
    it "a leitura deduz o evento da mudança de código e a cor/evento novos entram no aparelho já cadastrado" do
      robo = create(:device, site: site, driver: "xiaomi_miot", name: "Robô", address: { "host" => "10.0.0.7" }, credential: "b" * 32)
      Miio::Vacuum.points([]).each_with_index do |attrs, i|
        robo.points.create!(attrs.merge(site: site, key: "robo.p#{i}", data_type: Point::CAPABILITIES[attrs[:capability]]))
      end
      fim = robo.points.find_by!(name: "Limpeza concluída")
      expect(fim.address).to include("siid" => 2, "eiid" => 2, "event" => "sweep_complete")
      client = double("miio") # rubocop:disable RSpec/VerifiedDoubles
      allow(client).to receive(:get_properties).and_return({ [ 2, 2 ] => 4 }, { [ 2, 2 ] => 2 })
      Drivers::XiaomiMiot.poll(robo, client: client)
      expect(fim.reload.value).to be_nil
      Drivers::XiaomiMiot.poll(robo, client: client)
      expect(fim.reload.value).to include("event_type" => "sweep_complete", "from" => 4, "to" => 2)
      expect(robo.points.find_by!(name: "Situação").value).to eq("Carregando")

      integration = site.integrations.create!(driver: "xiaomi", name: "Xiaomi", status: "ok")
      robo.update!(integration: integration, external_id: "123")
      fim.destroy!
      novo = { "id" => "123", "kind" => "xiaomi_miot", "points" => Miio::Vacuum.points([]).map(&:deep_stringify_keys) }
      expect(Integrations.reconcile(integration, [ novo ])).to include(points: 1)
      expect(robo.points.where(name: "Limpeza concluída").count).to eq(1)
      expect(Integrations.reconcile(integration, [ novo ])).to include(points: 0)
    end
  end

  describe "Resumo do histórico de pontos" do
    it "kWh por dia com a mediana dos dias anteriores, vezes que ligou e tempo ligado; roda em sombra" do
      kwh = point("Medidor", "medidor", capability: "measure", unit: "kWh", device_class: "energy", writable: false, value: 30)
      bomba = point("Bomba", "bomba", value: false)
      zone = ActiveSupport::TimeZone[site.timezone]
      today = Time.current.in_time_zone(zone).beginning_of_day
      # acumulado: +1 kWh por dia nos 5 dias antes de ontem, +4 ontem
      rows = (1..6).map { |d| { point_id: kwh.id, bucket: "1h", starts_at: (today - d.days + 12.hours).utc, min: 0, max: 0, avg: 0, sum: 0, count: 1 } }
      acc = 10.0
      rows.reverse.each_with_index { |r, i| r[:last] = (acc += (i == 5 ? 4 : 1)) }
      rows << { point_id: kwh.id, bucket: "1h", starts_at: (today - 7.days + 12.hours).utc, min: 10, max: 10, avg: 10, sum: 10, count: 1, last: 10 }
      rows << { point_id: bomba.id, bucket: "1h", starts_at: (today - 1.day + 1.hour).utc, min: 0, max: 1, avg: 0, sum: 0, count: 1, last: 1, on_seconds: 1800 }
      ReadingRollup.insert_all!(rows.map { |r| { min: nil, max: nil, avg: nil, sum: nil, last: nil, on_seconds: nil }.merge(r) })
      Reading.insert_all!([ { point_id: bomba.id, at: (today - 1.day + 1.hour).utc, value: 1 }, { point_id: bomba.id, at: (today - 1.day + 2.hours).utc, value: 0 },
                            { point_id: bomba.id, at: (today - 2.days).utc, value: 1 } ])
      run = run!([ { "type" => "points_history", "query" => "device_class=energy", "op" => "energy_kwh", "period" => "days", "last_days" => 7, "response_variable" => "h" },
                   { "type" => "set", "var" => "lin", "value" => "{% for p in h.points %}{{ p.name }} {{ p.last }} {{ p.median_prev }} {{ p.prev_days }}{% endfor %}" },
                   { "type" => "points_history", "query" => "name=Bomba", "op" => "changes", "period" => "days", "last_days" => 1, "response_variable" => "v" },
                   { "type" => "points_history", "query" => "name=Bomba", "op" => "on_minutes", "period" => "last_month", "response_variable" => "m" },
                   { "type" => "points_history", "query" => "name=Bomba", "op" => "changes", "period" => "this_month", "to" => "1", "response_variable" => "t" } ], shadow: true)
      expect(run.status).to eq("done")
      vars = run.state["vars"]
      expect(vars["lin"]).to eq("Medidor 4.0 1.0 5")
      expect(vars["v"]["total"]).to eq(1)
      expect(vars["t"]["total"]).to be >= 1
      expect(vars["m"]["total"]).to eq(0)
      expect(Automations::Dsl.errors({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "points_history", "query" => "x=1", "op" => "changes", "period" => "days", "last_days" => 99 } ] }, site))
        .to include(a_string_including("filtro desconhecido"), a_string_including("dias de 1 a 62"))
    end
  end

  describe "Echo: som, música e volume (G12)" do
    it "manda as operações da Alexa e valida o volume" do
      echo_dev = create(:device, site: site, driver: "alexa", name: "Echo", external_id: "G0C", address: { "device_type" => "A3EH", "customer_id" => "CUST" })
      echo = create(:point, site: site, device: echo_dev, name: "Echo", key: "echo.falar", capability: "speaker", data_type: "json", writable: true)
      stub = stub_request(:post, "https://alexa.amazon.com.br/api/behaviors/preview").with(headers: { "csrf" => "C1" }).to_return(body: "")
      driver = Drivers::Alexa.new(client: Alexa::Client.new(cookies: { "session-id" => "S1", "csrf" => "C1" }))
      driver.execute(echo, "sound", "amzn_sfx_doorbell_chime_01")
      driver.execute(echo, "volume", "40")
      driver.execute(echo, "play", "spotify: rock nacional")
      driver.execute(echo, "play", "jazz")
      expect(stub).to have_been_requested.times(4)
      nodes = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.select { |s| s.uri.path == "/api/behaviors/preview" }
                     .map { |s| JSON.parse(JSON.parse(s.body)["sequenceJson"])["startNode"] }
      expect(nodes.map { |n| n["type"] }).to eq(%w[Alexa.Sound Alexa.DeviceControls.Volume Alexa.Music.PlaySearchPhrase Alexa.Music.PlaySearchPhrase])
      expect(nodes[0]["operationPayload"]).to include("soundStringId" => "amzn_sfx_doorbell_chime_01", "deviceSerialNumber" => "G0C", "customerId" => "CUST")
      expect(nodes[1]["operationPayload"]["value"]).to eq(40)
      expect(nodes[2]["operationPayload"]).to include("musicProviderId" => "SPOTIFY", "searchPhrase" => "rock nacional")
      expect(nodes[3]["operationPayload"]).to include("musicProviderId" => "AMAZON_MUSIC", "searchPhrase" => "jazz")
      expect { Points::Command.new(echo, "volume", 120).new_value }.to raise_error(Points::Command::Error, /0 a 100/)
      expect { driver.execute(echo, "sound", "som com espaço") }.to raise_error(Alexa::Client::Error, /Som inválido/)
    end
  end

  describe "importador do HA" do
    it "Jinja: expand(...) | map(attribute='last_changed') | max vira o mais recente dos pontos" do
      jinja = Blueprints::Jinja.new(->(e) { e.tr(".", "_") })
      expect(jinja.expr("{{ (now() - (expand('switch.a', 'switch.b') | map(attribute='last_changed') | max)).total_seconds() > 60 }}"))
        .to eq("(timestamp - max([[switch_a]].changed_at, [[switch_b]].changed_at)) > 60")
    end

    it "cor, brilho, alvo por etiqueta/área, mídia, atributo e espera de estado" do
      importer = Blueprints::HaImport.new("", nil, entities: true, labels: { "iluminacao" => "Iluminação" }, areas: { "sala" => "Sala de estar" })
      bp = importer.convert(Blueprints::HaImport.as_blueprint("script", "X", YAML.safe_load(<<~YAML)))
        sequence:
          - action: light.turn_on
            target: { entity_id: light.lamp }
            data: { rgb_color: [71, 69, 161], brightness_pct: 40, transition: 2 }
          - action: light.turn_on
            target: { entity_id: light.lamp }
            data: { color_temp_kelvin: "{{ k }}", effect: x }
          - action: homeassistant.turn_off
            target: { label_id: iluminacao }
          - action: light.turn_off
            target: { area_id: sala }
          - action: media_player.play_media
            target: { entity_id: media_player.echo }
            data: { media_content_type: sound, media_content_id: amzn_sfx_doorbell_chime_01 }
          - action: media_player.play_media
            target: { entity_id: media_player.echo }
            data: { media_content_type: SPOTIFY, media_content_id: rock }
          - action: media_player.volume_set
            target: { entity_id: media_player.echo }
            data: { volume_level: 0.35 }
          - action: media_player.play_media
            target: { entity_id: media_player.echo }
            data: { media_content_type: custom, media_content_id: oi }
          - wait_for_trigger: [ { trigger: state, entity_id: binary_sensor.mov, to: "off", for: { minutes: 2 } } ]
      YAML
      acts = bp["definition"]["actions"]
      expect(acts[0..2]).to eq([ { "type" => "command", "point" => { "!input" => "light_lamp" }, "command" => "on" },
                                 { "type" => "command", "point" => { "!input" => "light_lamp_dimmer" }, "command" => "set", "value" => 40 },
                                 { "type" => "command", "point" => { "!input" => "light_lamp_color" }, "command" => "set", "value" => { "rgb" => [ 71, 69, 161 ] } } ])
      expect(bp["inputs"].find { |i| i["key"] == "light_lamp_color" }).to include("label" => "light.lamp#color", "filter" => { "capability" => [ "color" ], "writable" => true })
      expect(acts.select { |a| a["type"] == "command_query" }).to eq([
        { "type" => "command_query", "query" => "tag=iluminação", "command" => "off" },
        { "type" => "command_query", "query" => "area=\"Sala de estar\" capability=onoff", "command" => "off" }
      ])
      expect(acts.select { |a| a["point"] == { "!input" => "media_player_echo" } }.map { |a| a.values_at("command", "value") })
        .to eq([ %w[sound amzn_sfx_doorbell_chime_01], [ "play", "SPOTIFY: rock" ], [ "volume", 35 ] ])
      expect(acts.last).to eq("type" => "wait_for", "conditions" => [ { "type" => "state", "point" => { "!input" => "binary_sensor_mov" }, "is" => false, "for" => "2m" } ],
                              "timeout" => "168h", "continue_on_timeout" => true)
      expect(bp["unsupported"]).to include("dados extras em light.turn_on (effect)", "color_temp_kelvin com template do HA (confira)",
                                           a_string_including("alvo por área em light"), "media_player.play_media (custom)")

      auto = Blueprints::HaImport.new("", nil, entities: true).convert(Blueprints::HaImport.as_blueprint("automation", "Y", YAML.safe_load(<<~YAML)))
        triggers: [ { trigger: state, entity_id: media_player.echo, attribute: last_called_timestamp, to: "on" } ]
        conditions: [ { condition: state, entity_id: media_player.echo, attribute: volume, state: "1" } ]
        actions: []
      YAML
      expect(auto["definition"]["triggers"]).to eq([ { "type" => "state", "point" => { "!input" => "media_player_echo" }, "attribute" => "last_called_timestamp", "to" => "on" } ])
      expect(auto["unsupported"]).to include("estado de atributo (volume)")
    end

    it "instalação: cor pelo ponto irmão, movimento da câmera sem aparelho no HA e evento do robô" do
      integration = site.integrations.create!(driver: "tuya", name: "Nuvem", status: "ok", inventory: [
        { "id" => "lamp1", "kind" => "tuya_cloud", "name" => "Lâmpada", "points" => [
          { "name" => "Luz", "capability" => "onoff", "writable" => true, "address" => { "dps" => "20", "code" => "switch_led" } },
          { "name" => "Cor", "capability" => "color", "data_type" => "json", "writable" => true, "address" => { "dps" => "24", "code" => "colour_data_v2", "color" => tuya_color } }
        ] },
        { "id" => "cam1abcdef", "kind" => "tuya_cloud", "name" => "Câmera", "points" => [
          { "name" => "Movimento", "capability" => "motion", "writable" => false, "address" => { "dps" => "212", "code" => "initiative_message" } }
        ] }
      ].to_json)
      allow(Integrations::TuyaPlugin).to receive(:refresh)
      integration
      robo = create(:device, site: site, driver: "xiaomi_miot", name: "Robô", external_id: "999")
      create(:point, site: site, device: robo, name: "Limpeza concluída", key: "robo.fim", capability: "event", data_type: "json", address: { "siid" => 2, "eiid" => 2 })
      files = {
        "area_registry" => { "data" => { "areas" => [] } },
        "label_registry" => { "data" => { "labels" => [ { "label_id" => "iluminacao", "name" => "Iluminação" } ] } },
        "device_registry" => { "data" => { "devices" => [ { "id" => "d1", "identifiers" => [ %w[tuya lamp1] ], "name" => "Lâmpada" },
                                                          { "id" => "d2", "identifiers" => [ %w[xiaomi_home 999] ], "name" => "Robô" } ] } },
        "entity_registry" => { "data" => { "entities" => [
          { "id" => "e1", "entity_id" => "light.lamp", "unique_id" => "tuya.lamp1switch_led", "device_id" => "d1", "platform" => "tuya", "labels" => [ "iluminacao" ] },
          { "id" => "e2", "entity_id" => "binary_sensor.cam_mov", "unique_id" => "cam1abcdef_camera_motion", "platform" => "tuya_camera_motion", "original_device_class" => "motion" },
          { "id" => "e3", "entity_id" => "event.robo_fim", "unique_id" => "xiaomi_home.robo_sweep_complete_e_2_2", "device_id" => "d2", "platform" => "xiaomi_home" },
          { "id" => "e4", "entity_id" => "automation.cor", "unique_id" => "1", "platform" => "automation" }
        ] } },
        "config_entries" => { "data" => { "entries" => [] } },
        "states" => [ { "entity_id" => "automation.cor", "state" => "on", "attributes" => {} } ],
        "automations" => <<~YAML
          - id: '1'
            alias: Cor
            triggers: [ { trigger: state, entity_id: binary_sensor.cam_mov, to: 'on' }, { trigger: state, entity_id: event.robo_fim } ]
            actions:
              - action: light.turn_on
                target: { entity_id: light.lamp }
                data: { rgb_color: [255, 0, 0] }
              - action: homeassistant.turn_off
                target: { label_id: iluminacao }
          - id: '2'
            alias: Atributo
            triggers: [ { trigger: state, entity_id: light.lamp, attribute: x } ]
            actions: []
        YAML
      }.transform_values { |v| v.is_a?(String) ? v : v.to_json }
      r = Integrations::HomeAssistantImport.call(site, files)
      refs = ExternalRef.map_for(site, "home_assistant", "Point")
      mov = Point.find(refs["binary_sensor.cam_mov"])
      expect(mov.name).to eq("Movimento")
      expect(Point.find(refs["event.robo_fim"]).key).to eq("robo.fim")
      cor = site.automations.find_by!(name: "Cor")
      expect(cor).to have_attributes(shadow: true, enabled: true)
      expect(cor.definition["triggers"].pluck("point")).to eq([ mov.id, Point.find_by!(key: "robo.fim").id ])
      acts = cor.definition["actions"]
      expect(acts[1]).to include("command" => "set", "point" => Point.find_by!(name: "Cor").id, "value" => { "rgb" => [ 255, 0, 0 ] })
      expect(acts[2]).to include("type" => "command_query", "query" => "tag=iluminação")
      expect(r.items.find { |i| i["name"] == "Cor" }["lossless"]).to be(true)
      expect(r.items.find { |i| i["name"] == "Atributo" }["notes"]).to include(a_string_including("não informa o atributo x"))
    end
  end
end
