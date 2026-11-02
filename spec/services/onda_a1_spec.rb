require "rails_helper"

# ondaA1: paridade com o HA nos grupos 1 e 2 (organização da casa,
# automações, templates, helpers, todo e calendário). Cada pacote numa seção.
RSpec.describe "ondaA1: paridade HA (organização e automações)" do
  let(:tenant) { create(:tenant) }
  let(:owner) { create(:user, tenant: tenant, role: "owner") }
  let(:site) { create(:site) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  describe "A1 andares" do
    let!(:terreo) { create(:area, site: site, name: "Térreo", kind: "floor", level: 0) }
    let!(:superior) { create(:area, site: site, name: "Superior", kind: "floor", level: 1) }
    let!(:sala) { create(:area, site: site, name: "Sala", parent: terreo) }
    let!(:canto) { create(:area, site: site, name: "Canto", parent: sala) }
    let!(:quarto) { create(:area, site: site, name: "Quarto", parent: superior) }
    let!(:luz_sala) { create(:point, site: site, device: create(:device, site: site, area: sala), name: "Luz", value: true) }
    let!(:luz_canto) { create(:point, site: site, device: create(:device, site: site, area: canto), name: "Abajur", value: true) }
    let!(:luz_quarto) { create(:point, site: site, device: create(:device, site: site, area: quarto), name: "Luz do quarto", value: true) }

    it "nível, andar de cada área (pela hierarquia) e rótulo do nível" do
      expect(canto.floor_area).to eq(terreo)
      expect(terreo.subtree_ids).to contain_exactly(terreo.id, sala.id, canto.id)
      expect([ terreo, superior, build(:area, kind: "floor", level: -1) ].map(&:level_label)).to eq([ "Térreo", "1º andar", "Subsolo 1" ])
      expect(build(:area, site: site, level: 999)).not_to be_valid
    end

    it "consulta `floor=` pega o andar inteiro (e serve ao comando por consulta)" do
      expect(Points::Query.new(site).call("floor=Térreo").map(&:id)).to contain_exactly(luz_sala.id, luz_canto.id)
      expect(Points::Query.new(site).call("floor=#{superior.id}").map(&:id)).to eq([ luz_quarto.id ])
      expect(Points::Query.new(site).call("floor=Inexistente")).to be_empty
    end

    it "voz: \"apague o térreo\" desliga só o andar" do
      r = Assist.call(site: site, user: owner, text: "apague o térreo")
      expect(r["text"]).to start_with("Desliguei")
      expect([ luz_sala, luz_canto, luz_quarto ].map { |p| p.reload.value }).to eq([ false, false, true ])
    end

    it "painel automático agrupa as áreas por andar, na ordem do nível" do
      views = Dashboards::Generator.new(site).call["views"]
      titles = views.first["sections"].map { |s| s["title"] }
      expect(titles & [ "Térreo", "Superior" ]).to eq([ "Térreo", "Superior" ])
    end

    it "importa os andares do HA e o alvo `floor_id` vira consulta" do
      files = { "floor_registry" => { "data" => { "floors" => [ { "floor_id" => "andar_1", "name" => "Andar de cima", "level" => 1 } ] } },
                "area_registry" => { "data" => { "areas" => [ { "id" => "suite", "name" => "Suíte", "floor_id" => "andar_1" } ] } } }
      Integrations::HomeAssistantImport.new(site, files).call
      floor = site.areas.find_by!(name: "Andar de cima")
      expect(floor).to have_attributes(kind: "floor", level: 1)
      expect(site.areas.find_by!(name: "Suíte").parent).to eq(floor)

      importer = Blueprints::HaImport.new("", nil, entities: true, areas: { "floor:andar_1" => "Andar de cima" })
      bp = importer.convert(Blueprints::HaImport.as_blueprint("script", "X", { "sequence" => [ { "action" => "light.turn_off", "target" => { "floor_id" => "andar_1" } } ] }))
      expect(bp["definition"]["actions"]).to eq([ { "type" => "command_query", "query" => "floor=\"Andar de cima\" capability=onoff", "command" => "off" } ])
    end
  end

  describe "A2 rótulos e categorias" do
    let(:room) { create(:area, site: site, name: "Sala") }
    let(:dev) { create(:device, site: site, area: room) }
    let!(:lamp) { create(:point, site: site, device: dev, name: "Luz", value: true) }
    let!(:other) { create(:point, site: site, device: create(:device, site: site), name: "Outra", value: true) }

    it "rótulo em ponto, aparelho, área e cena; o do aparelho e o da área valem para os pontos na consulta" do
      dev.update!(label_list: "Iluminação, Noite")
      room.update!(label_list: "térreo")
      other.update!(label_list: "externo")
      scene = site.scenes.create!(name: "Cinema", label_list: "noite", category: "  Lazer ", items: [ { "point_id" => lamp.id, "command" => "off" } ])
      expect(dev.reload.label_names).to eq(%w[iluminação noite])
      expect(scene.reload).to have_attributes(label_list: "noite", category: "Lazer")
      q = ->(text) { Points::Query.new(site).call(text).map(&:name) }
      expect(q.call("tag=iluminação")).to eq([ "Luz" ])
      expect(q.call("tag=térreo")).to eq([ "Luz" ])
      expect(q.call("tag=externo")).to eq([ "Outra" ])
      expect(Scene.labeled("noite")).to eq([ scene ])
      expect(Scene.labels_in(site.scenes)).to eq([ "noite" ])
    end

    it "modelo novo ganha rótulo só com `include Labelable` (plugin falso)" do
      fake = Class.new(ApplicationRecord) do
        self.table_name = "scenes"
        acts_as_tenant :tenant
        include Labelable
        def self.name = "TesteRotulado"
      end
      stub_const("TesteRotulado", fake)
      rec = TesteRotulado.create!(site_id: site.id, name: "Teste rótulo", items: [])
      rec.update!(label_list: "a, b, a")
      expect(rec.reload.label_names).to eq(%w[a b])
      expect(TesteRotulado.labeled("b").pluck(:id)).to eq([ rec.id ])
    end

    it "helper com categoria e rótulos pelo formulário" do
      point = HelperTypes.build(site, HelperTypes.plugin("toggle"))
      expect(HelperTypes.save(point, "name" => "Teste férias", "category" => "Modos", "label_list" => "casa")).to be true
      expect(point.reload).to have_attributes(category: "Modos", label_list: "casa")
    end
  end

  describe "A3 apelidos e Expor" do
    let(:room) { create(:area, site: site, name: "Sala", aliases: [ "living" ]) }
    let!(:lamp) { create(:point, site: site, device: create(:device, site: site, area: room), name: "Luz", value: false, aliases: [ " abajur ", "Abajur", "leitura" ]) }

    it "apelido de ponto e de área valem para a voz e a busca; tirar do Assist esconde da voz" do
      expect(lamp.aliases).to eq(%w[abajur leitura])
      expect(Assist.call(site: site, user: owner, text: "ligar a leitura")["text"]).to eq("Liguei Luz.")
      expect(Assist.call(site: site, user: owner, text: "desligar o living")["text"]).to eq("Desliguei Luz.")
      assist = Exposure.targets(site).find { |t| t.key == "assist" }
      expect(assist.set!(lamp, false)).to be_nil
      expect(assist.exposed?(lamp.reload)).to be false
      expect(Assist.find_points(site, "abajur")).to be_empty
    end

    it "assistente novo entra na tela só pelo registro (plugin falso)" do
      fake = Class.new(Exposure::Target) do
        def key = "teste"
        def title = "Teste"
        def icon = "cube"
        def exposed?(point) = point.expose.to_h["teste"] == true
        def set!(point, on, confirm: false) = point.update!(expose: point.expose.to_h.merge("teste" => on)) && nil
      end
      stub_const("Exposure::Teste", fake)
      stub_const("Exposure::PLUGINS", [ *Exposure::PLUGINS, "Teste" ])
      t = Exposure.targets(site).find { |x| x.key == "teste" }
      expect(t.title).to eq("Teste")
      t.set!(lamp, true)
      expect(t.exposed?(lamp.reload)).to be true
    end
  end

  describe "A4 unidades e configuração do local" do
    let(:dev) { create(:device, site: site) }
    let!(:temp) { create(:point, site: site, device: dev, name: "Temperatura", capability: "measure", unit: "°C", value: 25.0) }
    let(:helpers) { ApplicationController.helpers }

    before { Current.unit_systems = nil }

    it "converte só na tela: métrico, imperial e a unidade escolhida no ponto" do
      expect(helpers.point_value_text(temp)).to eq("25 °C")
      site.update!(unit_system: "imperial", currency: "usd", elevation: 1100, country: "us", language: "en")
      Current.unit_systems = nil
      expect(helpers.point_value_text(temp)).to eq("77 °F")
      expect(site.reload).to have_attributes(currency: "USD", country: "US")
      temp.update!(display_unit: "K")
      expect(helpers.point_value_text(temp)).to eq("298,15 K")
      expect(temp.reload.value).to eq(25.0)
      expect(temp.update(display_unit: "kg")).to be false
      expect(Units.convert(10, "km/h", "mph").round(3)).to eq(6.214)
      expect(site.update(unit_system: "lunar")).to be false
    end

    it "grandeza nova entra só pela tabela (plugin falso)" do
      stub_const("Units::DIMENSIONS", Units::DIMENSIONS.merge("teste" => { "x" => [ 1, 0 ], "y" => [ 2, 0 ] }))
      expect(Units.compatible("x")).to eq(%w[x y])
      expect(Units.convert(4, "x", "y")).to eq(2)
    end
  end

  describe "A5 gatilhos que faltavam" do
    let(:dev) { create(:device, site: site) }
    let!(:lamp) { create(:point, site: site, device: dev, name: "Luz", key: "sala.luz", value: false) }
    let!(:temp) { create(:point, site: site, device: dev, name: "Temperatura", key: "sala.temp", capability: "measure", value: 20) }

    def auto(triggers, conditions: [], actions: [ { "type" => "command", "point" => lamp.id, "command" => "toggle" } ])
      a = site.automations.create!(name: "Teste #{SecureRandom.hex(3)}")
      a.publish!({ "triggers" => triggers, "conditions" => conditions, "actions" => actions })
      a.update!(enabled: true)
      a
    end

    it "padrão de tempo: /5 nos minutos, hora fixa e segundos pelo job" do
      a = auto([ { "type" => "time_pattern", "minutes" => "/5" } ])
      Automations::Triggers.tick(Time.zone.parse("2026-11-02 10:07"))
      expect(a.runs.count).to eq(0)
      Automations::Triggers.tick(Time.zone.parse("2026-11-02 10:10"))
      expect(a.runs.count).to eq(1)
      b = auto([ { "type" => "time_pattern", "hours" => "8" } ])
      Automations::Triggers.tick(Time.zone.parse("2026-11-02 08:01"))
      expect(b.runs.count).to eq(0)
      c = auto([ { "type" => "time_pattern", "seconds" => "/20" } ])
      expect { Automations::Triggers.tick(Time.zone.parse("2026-11-02 08:01")) }.to have_enqueued_job(AutomationTickJob).exactly(2).times
      expect(c.runs.count).to eq(1) # o segundo 0 no próprio tick
      AutomationTickJob.perform_now(c.id, 0, "2026-11-02T08:01:20Z")
      expect(c.runs.count).to eq(2)
      expect(Automations::Dsl.errors({ "triggers" => [ { "type" => "time_pattern", "minutes" => "/0" } ], "actions" => [ { "type" => "stop" } ] }, site).join).to include("/N")
    end

    it "template: dispara na virada de falso para verdadeiro, não enquanto continua" do
      a = auto([ { "type" => "template", "expr" => "sala.temp > 28" } ])
      temp.report!(25)
      expect(a.runs.count).to eq(0)
      temp.report!(30)
      expect(a.runs.count).to eq(1)
      temp.report!(31)
      expect(a.runs.count).to eq(1)
      temp.report!(20)
      temp.report!(29)
      expect(a.runs.count).to eq(2)
    end

    it "MQTT com curinga e conteúdo; sistema iniciou/vai desligar; condição disparado por" do
      a = auto([ { "type" => "mqtt", "topic" => "casa/+/botao", "payload" => "single", "id" => "botao" }, { "type" => "system", "event" => "shutdown", "id" => "fim" } ],
               actions: [ { "type" => "if", "conditions" => [ { "type" => "trigger", "ids" => "botao" } ], "then" => [ { "type" => "command", "point" => lamp.id, "command" => "on" } ] } ])
      expect(Automations::TriggerTypes::MqttTrigger.topics).to include("casa/+/botao")
      Automations::TriggerTypes::MqttTrigger.receive("casa/sala/botao", "double")
      expect(a.runs.count).to eq(0)
      Automations::TriggerTypes::MqttTrigger.receive("casa/sala/botao", "single")
      expect(a.runs.last.trigger).to include("topic" => "casa/sala/botao", "id" => "botao")
      expect(lamp.reload.value).to be true
      lamp.report!(false)
      Automations::Triggers.system_stopping!
      expect(a.runs.count).to eq(2)
      expect(lamp.reload.value).to be false # o "se" só liga quando foi o botão
      expect(Automations::TriggerTypes::MqttTrigger.matches?("casa/#", "casa/a/b")).to be true
      expect(Automations::TriggerTypes::MqttTrigger.matches?("casa/+", "casa/a/b")).to be false
    end

    it "gatilho novo que vale enquanto algo é verdade entra só pelo registro (plugin falso)" do
      plugin = Class.new(Automations::TriggerTypes::Base) do
        describe key: "teste_ligada", label: "Teste: luz ligada"
        texts en: { label: "Test: light on" }, es: { label: "Prueba: luz encendida" }
        def self.reevaluate? = true
        def self.true_now?(_t, ctx) = ctx.points["sala.luz"].value == true
      end
      stub_const("Automations::TriggerTypes::TesteLigada", plugin)
      stub_const("Automations::TriggerTypes::PLUGINS", [ *Automations::TriggerTypes::PLUGINS, "TesteLigada" ])
      a = auto([ { "type" => "teste_ligada" } ], actions: [ { "type" => "stop" } ])
      temp.report!(1)
      lamp.report!(true)
      expect(a.runs.count).to eq(1)
    end

    it "importa do HA: time_pattern com segundos, template, mqtt e homeassistant shutdown" do
      importer = Blueprints::HaImport.new("", nil, entities: true)
      bp = importer.convert(Blueprints::HaImport.as_blueprint("automation", "X", YAML.safe_load(<<~YAML)))
        triggers:
          - { trigger: time_pattern, seconds: "/30" }
          - { trigger: template, value_template: "{{ states('sensor.temp') | float > 28 }}" }
          - { trigger: mqtt, topic: "zigbee2mqtt/botao", payload: "single" }
          - { trigger: homeassistant, event: shutdown }
        actions: [ { delay: 1 } ]
      YAML
      types = bp["definition"]["triggers"].map { |t| t["type"] }
      expect(types).to eq(%w[time_pattern template mqtt system])
      expect(bp["definition"]["triggers"][1]["expr"]).to include("> 28")
    end
  end

  describe "A7 ações que faltavam" do
    let(:dev) { create(:device, site: site) }
    let!(:a_luz) { create(:point, site: site, device: dev, name: "Luz A", key: "a.luz", value: false) }
    let!(:b_luz) { create(:point, site: site, device: dev, name: "Luz B", key: "b.luz", value: false) }

    def run_with(actions, triggers: [ { "type" => "manual" } ], conditions: [])
      a = site.automations.create!(name: "Teste #{SecureRandom.hex(3)}")
      a.publish!({ "triggers" => triggers, "conditions" => conditions, "actions" => actions })
      [ a, a.fire!({ "type" => "manual", "title" => "Teste" }, skip_conditions: conditions.empty?) ]
    end

    it "bloco desativado (enabled: false) fica no lugar e não roda; o editor liga e desliga" do
      _a, run = run_with([ { "type" => "command", "point" => a_luz.id, "command" => "on", "enabled" => false },
                           { "type" => "command", "point" => b_luz.id, "command" => "on" } ])
      expect(run.status).to eq("done")
      expect([ a_luz.reload.value, b_luz.reload.value ]).to eq([ false, true ])
      ok, checks = Automations::Conditions.new(Automations::Context.new(site: site)).check([ { "type" => "expr", "expr" => "1 = 2", "enabled" => false } ])
      expect([ ok, checks ]).to eq([ true, [] ])
      editor = Automations::Editor.new({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "stop" } ] }, site)
      editor.toggle("actions.0")
      expect(editor.definition["actions"][0]["enabled"]).to be false
      editor.toggle("actions.0")
      expect(editor.definition["actions"][0]).not_to have_key("enabled")
      expect(Automations::Dsl.errors({ "triggers" => [ { "type" => "manual", "enabled" => "x" } ], "actions" => [ { "type" => "stop" } ] }, site).join).to include("enabled")
    end

    it "em paralelo: cada ramo é uma execução própria e a automação só segue quando todos terminam" do
      a, run = run_with([
        { "type" => "parallel", "actions" => [
          { "type" => "sequence", "actions" => [ { "type" => "wait", "for" => "1m" }, { "type" => "command", "point" => a_luz.id, "command" => "on" } ] },
          { "type" => "command", "point" => b_luz.id, "command" => "on" }
        ] },
        { "type" => "set", "var" => "fim", "value" => "ok" }
      ])
      expect(run.reload.status).to eq("waiting")
      expect(b_luz.reload.value).to be true
      expect(a_luz.reload.value).to be false
      branches = a.runs.where(cause_run_id: run.id).order(:created_at).to_a
      expect(branches.map(&:status)).to eq(%w[waiting done])
      travel(2.minutes) { Automations::Engine.resume(branches.first.reload, branches.first.state["seq"]) }
      expect(a_luz.reload.value).to be true
      expect(run.reload.status).to eq("done")
      expect(run.state["vars"]).to include("fim" => "ok")
      expect(run.steps.map { |s| s["title"] }.join(" ")).to include("Em paralelo: 2 ramos")
    end

    it "em paralelo: ramo que falha faz a automação falhar; simulação roda os ramos em sequência" do
      _a, run = run_with([ { "type" => "parallel", "actions" => [ { "type" => "stop", "reason" => "quebrou", "error" => true }, { "type" => "command", "point" => b_luz.id, "command" => "on" } ] } ])
      expect(run.reload).to have_attributes(status: "failed", error: "quebrou")
      a = site.automations.create!(name: "Teste simulação")
      a.publish!({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "parallel", "actions" => [ { "type" => "command", "point" => a_luz.id, "command" => "on" }, { "type" => "command", "point" => b_luz.id, "command" => "off" } ] } ] })
      sim = a.simulate!(trigger: { "type" => "manual" }, skip_conditions: true)
      expect(sim.steps.count { |s| s["result"] == "simulated" }).to eq(2)
      expect(Automations::Dsl.errors({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "parallel", "actions" => [ { "type" => "stop" } ] } ] }, site).join).to include("2 a 10")
    end

    it "salvar e restaurar o estado (scene.create): a luz pisca e volta como estava" do
      a_luz.report!(true)
      _a, run = run_with([
        { "type" => "snapshot", "mode" => "save", "name" => "antes", "points" => [ a_luz.id ], "query" => "name=\"Luz B\"" },
        { "type" => "command", "point" => a_luz.id, "command" => "off" },
        { "type" => "command", "point" => b_luz.id, "command" => "on" },
        { "type" => "snapshot", "mode" => "restore", "name" => "antes" }
      ])
      expect(run.status).to eq("done")
      expect([ a_luz.reload.value, b_luz.reload.value ]).to eq([ true, false ])
      scene = site.scenes.find_by!(name: "Instantâneo: antes")
      expect(scene).to have_attributes(category: "Instantâneos")
      _b, bad = run_with([ { "type" => "snapshot", "mode" => "restore", "name" => "nunca" } ])
      expect(bad.error).to include("não existe")
    end

    it "publicar no MQTT com Liquid e retido" do
      expect(Mqtt::Listener).to receive(:publish).with("casa/a/luz", "on", retain: true)
      _a, run = run_with([ { "type" => "mqtt_publish", "topic" => "casa/a/luz", "payload" => "{{ 'on' }}", "retain" => true } ])
      expect(run.status).to eq("done")
      expect(Automations::Dsl.errors({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "mqtt_publish", "topic" => "casa/#" } ] }, site).join).to include("+ nem #")
    end
  end

  describe "A10 helpers que faltavam" do
    let(:dev) { create(:device, site: site) }
    let!(:temp) { create(:point, site: site, device: dev, name: "Temperatura", key: "sala.temp", capability: "measure", unit: "°C", value: 20.0) }
    let!(:umid) { create(:point, site: site, device: dev, name: "Umidade", key: "sala.umid", capability: "measure", unit: "%", value: 60.0) }
    let!(:fora) { create(:point, site: site, device: dev, name: "Fora", key: "fora.temp", capability: "measure", unit: "°C", value: 10.0) }
    let!(:rele) { create(:point, site: site, device: dev, name: "Relé", key: "sala.rele", value: false) }

    def helper(type, form = {})
      point = HelperTypes.build(site, HelperTypes.plugin(type))
      ok = HelperTypes.save(point, { "name" => "Teste #{type}" }.merge(form))
      raise "não salvou: #{point.errors.full_messages}" unless ok

      point.reload
    end

    it "estatística do histórico: horas, fração e vezes num valor" do
      t0 = Time.zone.parse("2026-11-02 08:00")
      travel_to(t0) { rele.report!(true) }
      travel_to(t0 + 1.hour) { rele.report!(false) }
      travel_to(t0 + 2.hours) { rele.report!(true) }
      h = travel_to(t0 + 3.hours) { helper("history_stats", "source" => rele.id, "state" => "on", "kind" => "time", "period" => "last_24h") }
      expect(h.value).to eq(2.0)
      HelperTypes::HistoryStats.refresh!(h.tap { |x| x.address["kind"] = "count" }, t0 + 3.hours)
      expect(h.reload.value).to eq(2)
    end

    it "período do dia vira a meia-noite e liga pelo relógio" do
      h = travel_to(Time.zone.parse("2026-11-02 12:00 -03:00")) { helper("times_of_day", "after" => "22:00", "before" => "06:00") }
      expect(h.value).to be false
      HelperTypes::TimesOfDay.tick(h, Time.zone.parse("2026-11-02 23:30 -03:00"))
      expect(h.reload.value).to be true
      expect(HelperTypes.save(HelperTypes.build(site, HelperTypes::TimesOfDay), "name" => "Teste sol", "after" => "sunset-30m", "before" => "06:00")).to be false # local sem latitude
    end

    it "aleatório fica na faixa e sorteia de novo pelo comando" do
      h = helper("random", "min_value" => "1", "max_value" => "3")
      expect(h.value).to be_between(1, 3)
      Points::Command.call(h, "press", nil, source: "web", user: nil)
      expect(h.reload.value).to be_between(1, 3)
    end

    it "filtro: média móvel, passa-baixa e descarte de pico" do
      m = helper("filter", "source" => temp.id, "kind" => "moving_average", "window" => "3")
      [ 21.0, 22.0, 23.0 ].each { |v| temp.report!(v) }
      expect(m.reload.value).to eq(22.0)
      o = helper("filter", "source" => temp.id, "kind" => "outlier", "window" => "5", "radius" => "2")
      temp.report!(23.5)
      temp.report!(90.0)
      expect(o.reload.value).to be < 30
    end

    it "mudar o tipo de um interruptor: aparece como luz, espelha e repassa o comando (com inverter)" do
      s = helper("switch_as_x", "source" => rele.id, "kind" => "light", "invert" => "1")
      expect(s).to have_attributes(device_class: "light", value: true)
      Points::Command.call(s, "off", nil, source: "web", user: nil)
      expect(rele.reload.value).to be true
      rele.report!(false)
      expect(s.reload.value).to be true
    end

    it "termostato liga e desliga com a tolerância; higrostato pela umidade" do
      t = helper("generic_thermostat", "source" => temp.id, "switch" => rele.id, "mode" => "heat", "tolerance" => "0.5", "target" => "22")
      temp.report!(21.0)
      expect(rele.reload.value).to be true
      expect(t.reload.attrs).to include("current" => 21.0, "action" => "heating")
      temp.report!(22.2) # dentro da tolerância: fica como está
      expect(rele.reload.value).to be true
      temp.report!(22.6)
      expect(rele.reload.value).to be false
      Points::Command.call(t.reload, "set", 25, source: "web", user: nil)
      expect(rele.reload.value).to be true
      rele.report!(false)
      g = helper("generic_hygrostat", "source" => umid.id, "switch" => rele.id, "mode" => "dry", "tolerance" => "3", "target" => "50")
      umid.report!(60.0)
      expect(rele.reload.value).to be true
      expect(g.reload.attrs["action"]).to eq("drying")
    end

    it "risco de mofo, bayesiano e compensação" do
      mold = helper("mold_indicator", "source" => temp.id, "humidity" => umid.id, "outdoor" => fora.id, "calibration" => "0.5")
      expect(mold.value).to be > 60
      expect(mold.attrs.keys).to include("dewpoint", "critical_temp")

      b = helper("bayesian", "prior" => "0.3", "threshold" => "0.6", "observations" => "sala.rele = on ; 0.9 ; 0.1\nsala.temp = 20 ; 0.7 ; 0.4")
      rele.report!(true)
      expect(b.reload.value).to be true
      expect(b.attrs["probability"]).to be > 0.6
      expect(HelperTypes.save(HelperTypes.build(site, HelperTypes::Bayesian), "name" => "Teste ruim", "observations" => "nada")).to be false

      c = helper("compensation", "source" => temp.id, "pairs" => "10: 11\n20: 21\n30: 31", "degree" => "1")
      temp.report!(25.0)
      expect(c.reload.value).to eq(26.0)
      expect(HelperTypes::Compensation.fit([ [ 0, 1 ], [ 1, 3 ], [ 2, 9 ] ], 2).map { |x| x.round(3) }).to eq([ 2.0, 0.0, 1.0 ])
    end

    it "todos os tipos novos têm formulário e textos em en/es" do
      %w[history_stats times_of_day random filter switch_as_x generic_thermostat generic_hygrostat mold_indicator bayesian compensation].each do |k|
        plugin = HelperTypes.plugin(k)
        expect(plugin).to be_present
        expect(plugin.texts["en"]).to include("title")
        expect(Rails.root.join("app/views/web/site_helpers/forms/_#{k}.html.erb")).to exist
      end
    end
  end

  describe "A11 listas de tarefas e agenda local" do
    def helper(type, name)
      point = HelperTypes.build(site, HelperTypes.plugin(type))
      raise point.errors.full_messages.to_sentence unless HelperTypes.save(point, "name" => name)

      point.reload
    end

    it "lista: adiciona, conclui, reabre, remove e limpa; o valor é quantos faltam" do
      l = helper("todo", "Lista de compras")
      cmd = ->(c, v = nil) { Points::Command.call(l, c, v, source: "web", user: nil).tap { l.reload } }
      cmd.call("add_item", "Leite")
      cmd.call("add_item", "Pão")
      expect(l.value).to eq(2)
      cmd.call("complete_item", "leite")
      expect(l.value).to eq(1)
      expect(HelperTypes::TodoList.items(l).map { |i| i.values_at("summary", "status") }).to eq([ %w[Leite completed], %w[Pão needs_action] ])
      cmd.call("reopen_item", "Leite")
      cmd.call("complete_item", "Leite")
      cmd.call("clear_completed")
      expect(HelperTypes::TodoList.items(l).pluck("summary")).to eq([ "Pão" ])
      expect(cmd.call("remove_item", "Café").error).to include("não está")
      expect(Points::Command.commands_for(l)).to include("add_item", "complete_item")
    end

    it "voz: adiciona e lê a lista pelo nome curto" do
      l = helper("todo", "Lista de compras")
      expect(Assist.call(site: site, user: owner, text: "adicione leite à lista de compras")["text"]).to eq("Coloquei leite em Lista de compras.")
      expect(Assist.call(site: site, user: owner, text: "coloca pão na lista de compras")["intent"]).to eq("todo_add")
      expect(Assist.call(site: site, user: owner, text: "o que tem na lista de compras")["text"]).to eq("Em Lista de compras: leite e pão.")
      expect(l.reload.value).to eq(2)
    end

    it "agenda local: evento com repetição vira os eventos da janela (como ICS) e serve ao gatilho de agenda" do
      cal = helper("local_calendar", "Agenda da casa")
      travel_to(Time.zone.parse("2026-11-02 08:00 -03:00")) do
        HelperTypes::LocalCalendar.add_event!(cal, "summary" => "Lixo reciclável", "start" => "2026-11-03 19:00", "end" => "2026-11-03 20:00", "repeat" => "weekly")
        HelperTypes::LocalCalendar.add_event!(cal, "summary" => "Feriado", "start" => "2026-11-15", "all_day" => "1")
      end
      ev = Calendars.events(cal.reload)
      expect(ev.count { |e| e["summary"] == "Lixo reciclável" }).to be >= 4
      expect(ev.find { |e| e["summary"] == "Feriado" }).to include("all_day" => true)
      expect(cal.value).to include("summary" => "Lixo reciclável")
      expect { HelperTypes::LocalCalendar.add_event!(cal, "summary" => "", "start" => "2026-11-03 19:00") }.to raise_error(ArgumentError)
      uid = cal.address["local"].first["uid"]
      HelperTypes::LocalCalendar.remove_event!(cal, uid)
      expect(Calendars.events(cal.reload).pluck("summary").uniq).to eq([ "Feriado" ])
    end

    it "automação cria evento na agenda local" do
      cal = helper("local_calendar", "Agenda da casa")
      a = site.automations.create!(name: "Teste agenda")
      a.publish!({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "calendar_create", "point" => cal.id, "summary" => "Revisar {{ site.name }}", "start" => "2026-11-10 09:00", "duration" => "30m" } ] })
      run = a.fire!({ "type" => "manual" }, skip_conditions: true)
      expect(run.status).to eq("done")
      e = cal.reload.address["local"].first
      expect(e["summary"]).to eq("Revisar #{site.name}")
      expect(Time.zone.parse(e["end"]) - Time.zone.parse(e["start"])).to eq(1800)
    end
  end
end
