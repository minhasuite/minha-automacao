require "rails_helper"

RSpec.describe "F8f: plugins da DSL, scripts e blueprints" do
  let(:tenant) { create(:tenant) }
  let(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Quadro") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, site: site, name: "Luz", key: "sala.luz", value: false, writable: true) } }
  let!(:motion) { within(tenant) { create(:point, device: device, site: site, name: "Movimento", key: "sala.movimento", capability: "motion", value: false) } }
  let!(:door) { within(tenant) { create(:point, device: device, site: site, name: "Porta", key: "sala.porta", capability: "contact", value: false) } }
  let!(:gate) { within(tenant) { create(:point, device: device, site: site, name: "Portão", key: "garagem.portao", capability: "gate", value: "closed", options: %w[open closed], risk: "critical", writable: true) } }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  before { device.update!(driver: "virtual") }

  describe "registro de gatilhos, condições e ações" do
    it "lista os tipos e monta o catálogo pelo plugin" do
      expect(Automations::TriggerTypes.keys).to eq(%w[state numeric time sun calendar alert manual webhook notification_action event])
      expect(Automations::ConditionTypes.keys).to eq(%w[state numeric time sun calendar expr and or not])
      expect(Automations::ActionTypes.keys).to include("command", "script", "wait_for", "repeat")
      expect(Automations::Dsl.catalog(:options).keys).to eq([ "option" ])
      expect(Automations::Dsl.form_fields).to include("point", "script", "timeout")
      expect(Automations::Dsl.form_fields).not_to include("fields", "days")
      expect(Automations::Dsl.spec(:actions, "nada")).to be_nil
    end

    it "tipo novo de ação entra só com a classe e a linha no registro (o motor não muda)" do
      plugin = Class.new(Automations::ActionTypes::Base) do
        describe key: "log", label: "Anotar", fields: [ f("text", :text, "Texto", required: true) ]
        def self.rules(node) = node["text"] == "proibido" ? [ "texto proibido." ] : []
        def self.call(e, _path, node)
          e.ctx.vars["anotado"] = node["text"]
          [ "Anotar: #{node['text']}", "ok" ]
        end
      end
      stub_const("Automations::ActionTypes::LogAction", plugin)
      stub_const("Automations::ActionTypes::PLUGINS", [ *Automations::ActionTypes::PLUGINS, "LogAction" ])

      definition = { "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "log", "text" => "oi" } ] }
      expect(Automations::Dsl.errors(definition, site)).to be_empty
      expect(Automations::Dsl.errors({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "log", "text" => "proibido" } ] }, site))
        .to eq([ "ações 1 (Anotar): texto proibido." ])
      editor = Automations::Editor.new(Automations::Dsl.empty, site)
      editor.update(editor.add("actions", "log"), { "text" => " oi " })
      expect(editor.definition["actions"]).to eq([ { "type" => "log", "text" => "oi" } ])

      a = Automation.create!(site: site, name: "Log")
      a.publish!(definition)
      run = a.fire!({ "type" => "manual", "title" => "Teste" }, skip_conditions: true)
      expect(run.status).to eq("done")
      expect(run.steps.last).to include("title" => "Anotar: oi", "result" => "ok")
      expect(run.state["vars"]).to include("anotado" => "oi")
    end

    it "tipo novo de gatilho de relógio dispara pelo plugin" do
      plugin = Class.new(Automations::TriggerTypes::Base) do
        describe key: "minute_zero", label: "Hora cheia"
        def self.clock = true
        def self.due?(_t, _site, local) = local.min.zero?
        def self.title(_t) = "Hora cheia"
      end
      stub_const("Automations::TriggerTypes::MinuteZero", plugin)
      stub_const("Automations::TriggerTypes::PLUGINS", [ *Automations::TriggerTypes::PLUGINS, "MinuteZero" ])
      a = Automation.create!(site: site, name: "Hora cheia")
      a.publish!({ "triggers" => [ { "type" => "minute_zero" } ], "actions" => [ { "type" => "command", "point" => lamp.id, "command" => "on" } ] })
      a.update!(enabled: true)

      Automations::Triggers.tick(Time.zone.parse("2026-10-30 10:07"))
      expect(a.runs.count).to eq(0)
      Automations::Triggers.tick(Time.zone.parse("2026-10-30 11:00"))
      expect(a.runs.sole.trigger["title"]).to eq("Hora cheia")
      expect(lamp.reload.value).to be true
    end

    it "condição desconhecida vira check falso com o motivo" do
      ctx = Automations::Context.new(site: site)
      ok, checks = Automations::Conditions.new(ctx).check([ { "type" => "nada" } ])
      expect(ok).to be false
      expect(checks.first["values"]).to include("desconhecida")
    end
  end

  describe "scripts" do
    let(:script) do
      site.scripts.create!(name: "Acender", mode: "parallel", fields: [
        { "name" => "alvo", "label" => "Luz", "type" => "point", "required" => true },
        { "name" => "recado", "label" => "Recado", "type" => "text", "default" => "pronto" },
        { "name" => "vezes", "label" => "Vezes", "type" => "number", "default" => 1 },
        { "name" => "forte", "label" => "Forte", "type" => "boolean" },
        { "name" => "modo", "label" => "Modo", "type" => "select", "options" => %w[a b] }
      ])
    end
    let(:sequence) do
      { "actions" => [ { "type" => "command", "point" => "$alvo", "command" => "on" },
                       { "type" => "notify", "channels" => [ "in_app" ], "title" => "{{ recado }} ({{ vezes }})" } ] }
    end

    it "valida os campos e a sequência (sem gatilho), com $campo no ponto" do
      bad = site.scripts.new(name: "X", fields: [ { "name" => "Ruim", "type" => "cor" }, { "name" => "Ruim", "type" => "select" } ])
      expect(bad).not_to be_valid
      expect(bad.errors[:fields].join).to include("letras minúsculas", "repetido", "tipo inválido", "opções")
      expect(site.automations.new(name: "Y", fields: [ { "name" => "a", "type" => "text" } ])).not_to be_valid

      expect(script.errors_in(sequence)).to be_empty
      expect(script.errors_in(sequence.merge("triggers" => [ { "type" => "manual" } ]))).to include(a_string_including("Script não tem gatilho"))
      expect(script.errors_in({ "actions" => [ { "type" => "command", "point" => "$nada", "command" => "on" } ] })).to include(a_string_including("campo $nada"))
      expect(script.working_draft).to eq("actions" => [])
    end

    it "converte os campos, aplica o padrão e barra o obrigatório" do
      expect(script.field_values({ "alvo" => "sala.luz", "vezes" => "2,5", "forte" => "1", "modo" => "b" }))
        .to eq("alvo" => lamp.id, "vezes" => 2.5, "forte" => true, "modo" => "b", "recado" => "pronto")
      expect { script.field_values({}) }.to raise_error(ArgumentError, /falta o campo Luz/)
      expect { script.field_values({ "alvo" => lamp.id, "modo" => "z" }) }.to raise_error(ArgumentError, /opção inválida/)
      expect { script.field_values({ "alvo" => "nada" }) }.to raise_error(ArgumentError, /ponto não existe/)
      expect { script.field_values({ "alvo" => lamp.id, "vezes" => "muito" }) }.to raise_error(ArgumentError, /número inválido/)
      expect { script.field_values({ "outro" => 1 }) }.to raise_error(ArgumentError, /campo desconhecido/)
      expect(script.run_risk({ "alvo" => gate.id })).to eq("critical")
      expect(script.field_defaults).to eq("recado" => "pronto", "vezes" => 1)
    end

    it "roda com os campos (trace próprio), vira ponto de capacidade script e roda pelo comando" do
      script.publish!(sequence)
      point = Scripts.point_for(script)
      expect(point).to have_attributes(capability: "script", name: "Acender", writable: true, risk: "normal")
      expect(point.device.external_id).to eq("scripts")
      expect(Points::Command.commands_for(point)).to eq([ "run" ])

      run = script.run_script!(script.field_values({ "alvo" => lamp.id }), title: "Teste")
      expect(run.status).to eq("done")
      expect(lamp.reload.value).to be true
      expect(Notification.last.title).to eq("pronto (1)")

      lamp.report!(false)
      cmd = Points::Command.call(point, "run", { "alvo" => "sala.luz", "recado" => "via painel" }, source: "web", user: nil)
      expect(cmd.status).to eq("confirmed")
      expect(lamp.reload.value).to be true
      expect(script.runs.count).to eq(2)

      failed = Points::Command.call(point, "run", {}, source: "web", user: nil)
      expect(failed).to have_attributes(status: "failed", error: a_string_including("Falta o campo Luz"))

      script.update!(name: "Acender tudo")
      expect(point.reload.name).to eq("Acender tudo")
      script.destroy!
      expect(Point.exists?(point.id)).to be false
    end

    it "não publicado ou já rodando: o comando do ponto falha com o motivo" do
      script.update!(mode: "single")
      point = Scripts.point_for(script)
      expect(Points::Command.call(point, "run", { "alvo" => lamp.id }, source: "web", user: nil).error).to include("Publique")
      script.publish!({ "actions" => [ { "type" => "wait", "for" => "5m" } ] })
      script.run_script!({}, title: "1")
      expect(Points::Command.call(point, "run", { "alvo" => lamp.id }, source: "web", user: nil).error).to include("Já está rodando")
      script.publish!({ "actions" => [ { "type" => "stop", "reason" => "quebrou", "error" => true } ] })
      script.runs.update_all(status: "done") # rubocop:disable Rails/SkipsModelValidations
      expect(Points::Command.call(point, "run", { "alvo" => lamp.id }, source: "web", user: nil).error).to include("quebrou")
    end

    it "automação chama o script com os campos; risco inclui os pontos do script e dos campos; laço é barrado" do
      script.publish!(sequence)
      a = Automation.create!(site: site, name: "Chama")
      definition = { "triggers" => [ { "type" => "manual" } ],
                     "actions" => [ { "type" => "script", "script" => script.id, "fields" => { "alvo" => gate.id, "recado" => "{{ trigger.title }}" } } ] }
      expect(a.errors_in(definition)).to be_empty
      expect(a.max_risk(definition)).to eq("critical")
      expect(a.errors_in({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "script", "script" => script.id, "fields" => { "x" => 1 } } ] }))
        .to include(a_string_including("campo desconhecido x"))
      expect(a.errors_in({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "script", "script" => script.id, "fields" => {} } ] }))
        .to include(a_string_including("falta luz"))

      definition["actions"][0]["fields"]["alvo"] = lamp.id
      a.publish!(definition)
      sim = a.simulate!(definition: a.definition)
      expect(sim.steps.last["detail"]).to include("Não executado (simulação)", "alvo: #{lamp.id}")
      run = a.fire!({ "type" => "manual", "title" => "Disparo" }, skip_conditions: true)
      expect(run.steps.last).to include("title" => "Executar script Acender", "result" => "ok")
      child = script.runs.real.sole
      expect(child.cause_run_id).to eq(run.id)
      expect(child.trigger["title"]).to eq("Chamado por Chama")
      expect(Notification.last.title).to eq("Disparo (1)")

      looping = site.scripts.create!(name: "Eco")
      looping.publish!({ "actions" => [ { "type" => "script", "script" => looping.id } ] })
      expect(looping.max_risk(looping.definition)).to eq("normal")
      out = looping.run_script!({}, title: "1")
      expect(out.steps.last).to include("result" => "skipped", "detail" => a_string_including("Laço evitado"))
      expect(looping.runs.real.find_by(status: "loop")).to be_present
    end

    it "script removido ou com falha para a automação" do
      script.publish!({ "actions" => [ { "type" => "stop", "error" => true, "reason" => "não deu" } ] })
      a = Automation.create!(site: site, name: "Chama")
      a.publish!({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "script", "script" => script.id, "fields" => { "alvo" => lamp.id } } ] })
      expect(a.fire!({ "type" => "manual" }, skip_conditions: true)).to have_attributes(status: "failed", error: a_string_including("não deu"))
      script.update!(mode: "single")
      script.publish!({ "actions" => [ { "type" => "wait", "for" => "5m" } ] })
      script.run_script!({}, title: "ocupa")
      expect(a.fire!({ "type" => "manual" }, skip_conditions: true).steps.last).to include("result" => "skipped")
      Automation.where(id: script.id).delete_all
      expect(a.fire!({ "type" => "manual" }, skip_conditions: true).error).to include("Script removido")
    end
  end

  describe "cenas" do
    it "captura o estado atual sem comandar nada" do
      lamp.report!(true)
      level = create(:point, device: device, site: site, name: "Dimmer", capability: "dimmer", value: 40, writable: true, min: 0, max: 100)
      mode = create(:point, device: device, site: site, name: "Modo", capability: "enum", value: "eco", options: %w[eco turbo], writable: true)
      blank = create(:point, device: device, site: site, name: "Sem valor", capability: "onoff", writable: true)
      expect(Scene.capture(lamp)).to eq("point_id" => lamp.id, "command" => "on")
      expect(Scene.capture(level)).to eq("point_id" => level.id, "command" => "set", "value" => 40)
      expect(Scene.capture(mode)).to eq("point_id" => mode.id, "command" => "select", "value" => "eco")
      expect(Scene.capture(blank)).to be_nil
      expect(Scene.capture(door)).to be_nil
      expect(Command.count).to eq(0)
    end
  end

  describe "blueprints" do
    before { Blueprints.sync_builtin!(site) }

    let(:motion_bp) { site.blueprints.find_by!(source: "builtin:luz_por_movimento") }

    it "cria os 3 prontos uma vez só e atualiza quando o arquivo muda (propagando)" do
      expect(site.blueprints.pluck(:name)).to contain_exactly("Ligar luz por movimento com tempo de desligar",
                                                              "Avisar quando sensor ficar aberto por X minutos", "Desligar após X minutos ligado")
      Blueprints.sync_builtin!(site)
      expect(site.blueprints.count).to eq(3)
      expect(motion_bp).to have_attributes(builtin?: true, source_label: "Pronto", domain_label: "Automação", version: 1)

      a = motion_bp.create_automation!(name: "Sala", values: { "sensor" => motion.id, "luz" => "sala.luz" })
      expect(a).to have_attributes(published?: true, enabled: false, mode: "restart", blueprint_version: 1, blueprint_outdated?: false)
      expect(a.definition["triggers"]).to eq([ { "type" => "state", "point" => motion.id, "to" => true } ])
      expect(a.definition["actions"][1]["conditions"][0]).to include("for" => "2m")

      changed = Blueprints.builtin.transform_values(&:deep_dup)
      changed["builtin:luz_por_movimento"]["definition"]["actions"][1]["timeout"] = "3h"
      allow(Blueprints).to receive(:builtin).and_return(changed)
      Blueprints.sync_builtin!(site)
      expect(motion_bp.reload.version).to eq(2)
      a.reload
      expect(a.blueprint_outdated?).to be true
      expect(a.draft["actions"][1]["timeout"]).to eq("3h")
      expect(a.definition["actions"][1]["timeout"]).to eq("6h")
      a.publish!
      expect(a.reload.blueprint_outdated?).to be false
    end

    it "valida as entradas pelo tipo e pelo filtro" do
      _defn, _clean, errors = motion_bp.instantiate({ "sensor" => lamp.id, "luz" => "nada", "tempo" => "logo" })
      expect(errors).to contain_exactly(a_string_including("Luz não serve (precisa ser sensor de movimento ou sensor de abertura)"),
                                        "Luz: ponto não existe neste local.", a_string_including("duração inválida"), "Falta luz.", "Falta sensor de movimento.")
      area = create(:area, site: site, name: "Cozinha")
      bp = site.blueprints.create!(name: "Tipos", inputs: [
        { "key" => "n", "label" => "N", "type" => "number" }, { "key" => "b", "label" => "B", "type" => "boolean", "default" => false },
        { "key" => "s", "label" => "S", "type" => "select", "options" => %w[x y] }, { "key" => "h", "label" => "H", "type" => "time", "required" => false },
        { "key" => "t", "label" => "T", "type" => "text", "required" => false },
        { "key" => "p", "label" => "P", "type" => "point", "required" => false, "filter" => { "area" => "Cozinha", "writable" => true } }
      ], definition: { "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "set", "var" => "x", "expr" => { "!input" => "n" } } ] })
      defn, clean, errors = bp.instantiate({ "n" => "2,0", "s" => "y", "h" => "07:30:00", "t" => "oi" })
      expect(errors).to be_empty
      expect(clean).to eq("n" => 2, "b" => false, "s" => "y", "h" => "07:30", "t" => "oi")
      expect(defn["actions"][0]["expr"]).to eq(2)
      _, _, errors = bp.instantiate({ "n" => "x", "s" => "z", "h" => "25:00", "p" => door.id })
      expect(errors).to include("N: número inválido.", "S: opção inválida.", "H: horário inválido.", a_string_including("precisa receber comando"))
      lamp.update!(area: nil)
      _, _, errors = bp.instantiate({ "n" => 1, "s" => "x", "p" => lamp.id })
      expect(errors).to include(a_string_including("precisa ser da área Cozinha"))
      lamp.update!(area: area)
      expect(bp.instantiate({ "n" => 1, "s" => "x", "p" => lamp.id }).last).to be_empty
      expect { bp.create_automation!(name: "", values: {}) }.to raise_error(ArgumentError, /Falta/)
      expect(site.blueprints.new(name: "R", inputs: [ { "key" => "A" }, { "key" => "A", "type" => "select" } ])).not_to be_valid
    end

    it "script por blueprint; DSL que não fecha fica no rascunho" do
      bp = site.blueprints.create!(name: "Pisca", domain: "script", inputs: [ { "key" => "luz", "label" => "Luz", "type" => "point" } ],
                                   definition: { "actions" => [ { "type" => "command", "point" => { "!input" => "luz" }, "command" => "on" } ] })
      s = bp.create_automation!(name: "Pisca sala", values: { "luz" => lamp.id })
      expect(s).to have_attributes(kind: "script", published?: true)
      broken = bp.create_automation!(name: "Pisca porta", values: { "luz" => door.id })
      expect(broken).to have_attributes(published?: false)
      expect(broken.errors_in(broken.draft)).to include(a_string_including("não recebe comando"))
      bp.update!(definition: { "actions" => [ { "type" => "command", "point" => { "!input" => "luz" }, "command" => "off" } ] })
      expect(s.reload.draft["actions"][0]["command"]).to eq("off")
      expect(bp.rebuild_draft!(s)).to be_empty
    end

    describe "importar do HA" do
      it "converte o motion_light oficial e lista o que não suporta" do
        attrs = Blueprints::HaImport.call(file_fixture("ha_motion_light.yaml").read)
        expect(attrs).to include("name" => "Motion-activated Light", "domain" => "automation", "mode" => "restart", "source" => "ha")
        expect(attrs["source_url"]).to include("github.com/home-assistant")
        expect(attrs["inputs"]).to eq([
          { "key" => "motion_entity", "label" => "Motion Sensor", "type" => "point", "filter" => { "capability" => [ "motion" ] } },
          { "key" => "light_target", "label" => "Light", "type" => "point", "filter" => { "capability" => [ "onoff" ], "writable" => true } },
          { "key" => "no_motion_wait", "label" => "Wait time", "description" => "Time to leave the light on after last motion is detected.", "type" => "number", "default" => 120 }
        ])
        expect(attrs["definition"]["triggers"]).to eq([ { "type" => "state", "point" => { "!input" => "motion_entity" }, "to" => true, "from" => false } ])
        expect(attrs["definition"]["actions"].pluck("type", "command")).to eq([ %w[command on], [ "wait", nil ], %w[command off] ])
        expect(attrs["unsupported"]).to eq([ "ação wait_for_trigger" ])

        bp = site.blueprints.create!(attrs)
        a = bp.create_automation!(name: "Do HA", values: { "motion_entity" => motion.id, "light_target" => lamp.id })
        expect(a.published?).to be true
        expect(a.definition["actions"][1]).to eq("type" => "wait", "for" => 120)
      end

      it "converte entradas, gatilhos, condições e ações variadas e anota o resto" do
        attrs = Blueprints::HaImport.call(file_fixture("ha_varios.yaml").read, source_url: "https://gist.github.com/x/1")
        inputs = attrs["inputs"].index_by { |i| i["key"] }
        expect(inputs.keys).to eq(%w[temp door fan limite ativo modo hora espera nota])
        expect(inputs["temp"]["filter"]).to eq("capability" => [ "measure" ])
        expect(inputs["door"]["filter"]).to eq("capability" => [ "contact" ])
        expect(inputs["modo"]).to include("type" => "select", "options" => %w[rapido lento])
        expect(inputs["hora"]["default"]).to eq("07:30")
        expect(inputs["espera"]["default"]).to eq("5m")
        d = attrs["definition"]
        expect(d["triggers"]).to eq([
          { "type" => "numeric", "point" => { "!input" => "temp" }, "above" => { "!input" => "limite" }, "for" => "1m" },
          { "type" => "time", "at" => { "!input" => "hora" } }, { "type" => "sun", "event" => "sunset", "offset" => "-15m" }
        ])
        expect(d["conditions"]).to eq([
          { "type" => "state", "point" => { "!input" => "door" }, "is" => false },
          { "type" => "time", "after" => "18:00", "days" => [ 1, 5 ] },
          { "type" => "numeric", "point" => { "!input" => "temp" }, "below" => 40 }, { "type" => "expr", "expr" => "true" }
        ])
        expect(d["actions"]).to eq([
          { "type" => "set", "var" => "x", "expr" => "1" }, { "type" => "command", "point" => { "!input" => "fan" }, "command" => "on" },
          { "type" => "notify", "channels" => %w[in_app push], "title" => "Calor", "message" => "Está {{ states('sensor.x') }} graus" },
          { "type" => "notify", "channels" => [ "in_app" ], "title" => "Aviso", "message" => "Pronto" },
          { "type" => "wait", "for" => "2m" }, { "type" => "wait", "for" => { "!input" => "espera" } }
        ])
        expect(attrs["mode"]).to eq("queued")
        expect(attrs["unsupported"]).to include("entrada alvo (selector area)", "entrada fan: várias entidades (aqui é um ponto só)",
                                                "entidade fixa sensor.fixa (use uma entrada de ponto)", "gatilho mqtt", "gatilho time por entidade",
                                                "condição template", "dados extras em fan.turn_on (brilho, cor...)",
                                                a_string_including("template do HA"), "ação scene.turn_on", "ação choose")
      end

      it "erros claros: vazio, YAML inválido, sem blueprint, domínio" do
        expect { Blueprints::HaImport.call(" ") }.to raise_error(Blueprints::HaImport::Error, /Cole/)
        expect { Blueprints::HaImport.call("a: [") }.to raise_error(Blueprints::HaImport::Error, /YAML inválido/)
        expect { Blueprints::HaImport.call("- 1") }.to raise_error(Blueprints::HaImport::Error, /objeto/)
        expect { Blueprints::HaImport.call("a: 1") }.to raise_error(Blueprints::HaImport::Error, /falta a chave blueprint/)
        expect { Blueprints::HaImport.call("blueprint: { domain: template }") }.to raise_error(Blueprints::HaImport::Error, /template/)
        script = Blueprints::HaImport.call("blueprint: { name: S, domain: script }\nsequence:\n  - service: switch.toggle\n    entity_id: switch.x\n  - delay: 10")
        expect(script).to include("domain" => "script", "definition" => { "actions" => [ { "type" => "wait", "for" => "10s" } ] })
        expect(script["unsupported"]).to eq([ "entidade fixa switch.x (use uma entrada de ponto)" ])
      end

      it "baixa do GitHub, gist e comunidade (só esses endereços)" do
        yaml = file_fixture("ha_motion_light.yaml").read
        stub_request(:get, "https://raw.githubusercontent.com/u/r/main/bp.yaml").to_return(body: yaml)
        expect(Blueprints::HaImport.fetch("https://github.com/u/r/blob/main/bp.yaml")).to include("Motion-activated")
        stub_request(:get, "https://gist.githubusercontent.com/u/abc/raw").to_return(status: 302, headers: { "Location" => "https://gist.githubusercontent.com/u/abc/raw/1/bp.yaml" })
        stub_request(:get, "https://gist.githubusercontent.com/u/abc/raw/1/bp.yaml").to_return(body: yaml)
        expect(Blueprints::HaImport.fetch("https://gist.github.com/u/abc/")).to include("Motion-activated")
        cooked = "<p>Use:</p><pre><code class=\"lang-yaml\">#{CGI.escapeHTML(yaml)}</code></pre>"
        stub_request(:get, "https://community.home-assistant.io/t/123.json").to_return(body: { post_stream: { posts: [ { cooked: cooked } ] } }.to_json)
        expect(Blueprints::HaImport.fetch("https://community.home-assistant.io/t/luz/123/4")).to include("!input motion_entity")
        stub_request(:get, "https://community.home-assistant.io/t/9.json").to_return(body: { post_stream: { posts: [ { cooked: "<p>nada</p>" } ] } }.to_json)
        expect { Blueprints::HaImport.fetch("https://community.home-assistant.io/t/x/9") }.to raise_error(Blueprints::HaImport::Error, /Não achei/)
        stub_request(:get, "https://community.home-assistant.io/t/8.json").to_return(body: "<html>")
        expect { Blueprints::HaImport.fetch("https://community.home-assistant.io/t/x/8") }.to raise_error(Blueprints::HaImport::Error, /inválida/)
        stub_request(:get, "https://raw.githubusercontent.com/u/r/main/x.yaml").to_return(status: 404)
        expect { Blueprints::HaImport.fetch("https://raw.githubusercontent.com/u/r/main/x.yaml") }.to raise_error(Blueprints::HaImport::Error, /404/)
        stub_request(:get, "https://raw.githubusercontent.com/u/r/main/big.yaml").to_return(body: "a" * 200_001)
        expect { Blueprints::HaImport.fetch("https://raw.githubusercontent.com/u/r/main/big.yaml") }.to raise_error(Blueprints::HaImport::Error, /grande/)
        stub_request(:get, "https://raw.githubusercontent.com/u/r/main/t.yaml").to_timeout
        expect { Blueprints::HaImport.fetch("https://raw.githubusercontent.com/u/r/main/t.yaml") }.to raise_error(Blueprints::HaImport::Error, /Não consegui/)
        stub_request(:get, "https://raw.githubusercontent.com/u/r/main/r.yaml").to_return(status: 301, headers: { "Location" => "https://evil.example.com/x" })
        expect { Blueprints::HaImport.fetch("https://raw.githubusercontent.com/u/r/main/r.yaml") }.to raise_error(Blueprints::HaImport::Error, /fora dos permitidos/)
        expect { Blueprints::HaImport.fetch("http://github.com/x") }.to raise_error(Blueprints::HaImport::Error, /https/)
        expect { Blueprints::HaImport.fetch("https://example.com/x") }.to raise_error(Blueprints::HaImport::Error, /https/)
        expect { Blueprints::HaImport.fetch("https://exa mple") }.to raise_error(Blueprints::HaImport::Error, /inválido/)
      end
    end
  end
end
