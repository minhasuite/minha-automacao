require "rails_helper"

# F10: modo sombra (nada sai para aparelho, aviso, rede ou IA), o de-para e
# o comparador com uma fonte de referência (plugin). Tudo sintético.
RSpec.describe "F10: modo sombra e comparador" do
  include ActiveJob::TestHelper

  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, name: "Local") }
  let(:device) { create(:device, site: site, driver: "tuya_local", name: "Aparelho") }
  let!(:lamp) { create(:point, site: site, device: device, name: "Lâmpada", key: "ap.luz", capability: "onoff", writable: true, value: false) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { travel_to(Time.zone.parse("2026-10-31 12:00")) { ex.run } } }

  def automation(actions, shadow: true, kind: "automation", name: nil)
    a = Automation.create!(site: site, name: name || "A #{SecureRandom.hex(3)}", kind: kind, mode: "parallel", shadow: shadow)
    a.update_columns(definition: (kind == "script" ? {} : Automations::Dsl.empty).merge("actions" => actions), version: 1) # rubocop:disable Rails/SkipsModelValidations
    a
  end

  def run!(actions, shadow: true)
    automation(actions, shadow: shadow).fire!({ "type" => "manual", "title" => "Teste" }, skip_conditions: true)
  end

  def nothing_left!
    expect(Command.where(point_id: lamp.id)).to be_empty
    expect(enqueued_jobs.map { |j| j["job_class"] }).not_to include("ExecuteCommandJob")
    expect(Notification.count).to eq(0)
    expect(AiCall.count).to eq(0)
    expect(a_request(:any, /.*/)).not_to have_been_made
    expect(lamp.reload.value).to be(false)
  end

  # Valor de exemplo por tipo de campo, para montar cada ação registrada.
  def sample(fd, ctx)
    { writable_point: lamp.id, point: lamp.id, points: [ lamp.id ], command: "on", scene: ctx[:scene].id, script: ctx[:script].id,
      channels: %w[in_app push], recipient: "admins", text: "x", template: "x", prompt: "x", duration: "1s", number: 1, bool: false,
      var: "v", expr: "1", conditions: [], actions: [], options: [ { "conditions" => [], "actions" => [] } ], kv: { "a" => "b" },
      dataset: ctx[:dataset].id, secret: Automations::Dsl.encrypt_secret("s"), select: -> { fd.choices.keys.first }, camera: lamp.id, cameras: [ lamp.id ],
      areas: [], tags: [], buttons: [], script_fields: {}, value: nil, ai_output: nil }.fetch(fd.kind) { "x" }.then { |v| v.is_a?(Proc) ? v.call : v }
  end

  describe "bloqueio do executor" do
    let(:ctx) do
      { scene: site.scenes.create!(name: "Cena", items: [ { "point_id" => lamp.id, "command" => "on" } ]),
        script: automation([ { "type" => "command", "point" => lamp.id, "command" => "on" } ], kind: "script", shadow: false, name: "Script"),
        dataset: site.datasets.create!(name: "Dados", key: "dados", fields: [ { "name" => "x", "type" => "text" } ]) }
    end

    it "nenhum tipo de ação registrado chega a um aparelho, aviso, rede ou IA" do
      Automations::ActionTypes.plugins.each do |plugin|
        node = plugin.defaults.merge("type" => plugin.key)
        plugin.fields.each { |fd| node[fd.name] = sample(fd, ctx) unless node.key?(fd.name) || %w[continue_on_error response_variable].include?(fd.name) }
        node.compact!
        node["then"] = [ { "type" => "command", "point" => lamp.id, "command" => "on" } ] if plugin.key == "if"
        node["count"] = 1 if plugin.key == "repeat"
        node.slice!("type", "count", "actions") if plugin.key == "repeat"
        node["actions"] = [ { "type" => "command", "point" => lamp.id, "command" => "on" } ] if plugin.key == "repeat"
        run!([ node ])
      end
      nothing_left!
      expect(ShadowAction.where(action: "command").count).to be >= 3 # comando, se/então, repetir e o script chamado
      expect(ShadowAction.where(action: %w[notify speak http ai_task ai_data tts stt dataset_record scene]).pluck(:action).uniq.size).to eq(9)
      expect(AutomationRun.where(automation_id: ctx[:script].id).pick(:shadow)).to be(true) # script chamado herda a sombra
    end

    it "ação nova que não se declara segura nasce segurada, e a rede pega quem escapa" do
      sneaky = Class.new(Automations::ActionTypes::Base) do
        describe key: "falso_comando", label: "Comando falso", fields: []
        def self.call(_e, _path, _node)
          Points::Command.call(Point.find_by!(key: "ap.luz"), "on", source: "automation", user: nil)
          [ "Ligou direto", "ok" ]
        end
      end
      unsafe = Class.new(sneaky) { def self.shadow_safe?(_e, _n) = true }
      unsafe.describe(key: "falso_seguro", label: "Falso seguro", fields: [])
      stub_const("Automations::ActionTypes::FalsoComando", sneaky)
      stub_const("Automations::ActionTypes::FalsoSeguro", unsafe)
      stub_const("Automations::ActionTypes::PLUGINS", Automations::ActionTypes::PLUGINS + %w[FalsoComando FalsoSeguro])

      run = run!([ { "type" => "falso_comando" } ])
      expect(run.steps.last).to include("result" => "shadow")
      run = run!([ { "type" => "falso_seguro" } ])
      expect(run.status).to eq("failed")
      expect(run.error).to include("Em sombra")
      nothing_left!
      expect(ShadowAction.pluck(:title)).to include("Ligar Lâmpada")
    end

    it "helper interno e script rodam e ficam registrados; grupo e aparelho não" do
      helper = HelperTypes.build(site, HelperTypes.plugin("toggle")).tap { |p| HelperTypes.save(p, "name" => "Modo") }
      group = HelperTypes.build(site, HelperTypes.plugin("group"))
      other = create(:point, site: site, device: device, name: "Outra", capability: "onoff", writable: true, value: false)
      HelperTypes.save(group, "name" => "Grupo", "members" => [ lamp.id, other.id ], "mode" => "any")
      run!([ { "type" => "command", "point" => helper.id, "command" => "on" }, { "type" => "command", "point" => group.id, "command" => "on" } ])
      expect(helper.reload.value).to be(true)
      expect(ShadowAction.find_by(title: "Ligar Modo")).to have_attributes(executed: true)
      expect(ShadowAction.find_by(title: "Ligar Grupo")).to have_attributes(executed: false)
      nothing_left!
    end

    it "fora da sombra continua comandando" do
      run!([ { "type" => "command", "point" => lamp.id, "command" => "on" } ], shadow: false)
      expect(Command.where(point_id: lamp.id).count).to eq(1)
    end

    it "rede de segurança: aviso, HTTP e IA levantam Blocked com sombra na thread" do
      Shadow.within(site_id: site.id) do
        expect { Notifier.deliver!(%w[in_app], kind: "x", title: "Oi") }.to raise_error(Shadow::Blocked)
        expect { SafeHttp.get("https://example.com") }.to raise_error(Shadow::Blocked)
        expect { Ai::Request.call(tenant: tenant, prompt: "x", source: "automacao") }.to raise_error(Shadow::Blocked)
      end
      expect(ShadowAction.where(action: "blocked").count).to eq(3)
      expect(Shadow.current).to be_nil
    end
  end

  describe "sombra do local, da instalação e das cenas" do
    it "local em sombra: comando automático (primitivas) é segurado; o da pessoa passa" do
      site.update!(shadow: true)
      expect { Points::Command.call(lamp, "on", source: "automation", user: nil) }.to raise_error(Shadow::Blocked)
      expect(Points::Command.call(lamp, "on", source: "web", user: nil)).to be_a(Command)
      a = automation([ { "type" => "command", "point" => lamp.id, "command" => "off" } ], shadow: false)
      expect(Shadow.active?(a)).to be(true)
      expect(a.fire!({ "type" => "manual" }).shadow).to be(true)
    end

    it "instalação em sombra vale para todos os locais" do
      tenant.update!(settings: tenant.settings.merge("shadow" => true))
      expect(Shadow.site?(site.reload)).to be(true)
    end

    it "cena em sombra registra cada linha e não envia nada" do
      scene = site.scenes.create!(name: "Noite", items: [ { "point_id" => lamp.id, "command" => "on" } ], shadow: true)
      commands, failures = scene.activate!(source: "web", user: nil)
      expect(commands).to be_empty
      expect(failures.first).to include("Em sombra")
      expect(ShadowAction.find_by(scene_id: scene.id).effects).to eq([ { "point_id" => lamp.id, "command" => "on", "value" => nil } ])
    end

    it "primitivas do local em sombra (espelho, agenda) ficam marcadas" do
      site.update!(shadow: true)
      seen = nil
      allow(PointLink).to receive(:propagate) { seen = Shadow.current }
      Automations.on_change(lamp, "good", false)
      expect(seen&.site_id).to eq(site.id)
    end
  end

  describe "comparador (fonte de referência como plugin)" do
    let(:fake) do
      Class.new(Integrations::Plugin) do
        describe key: "ref_falsa", title: "Referência falsa", icon: "link", description: "teste"
        def self.reference(_integration, _from, _to, entries:) = entries
        def self.state_for(command, value) = { "on" => "ligado", "off" => "desligado", "set" => value.to_s }.fetch(command, "*")
      end
    end

    before do
      stub_const("Integrations::RefFalsa", fake)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[RefFalsa])
    end

    it "classifica cada automação pelo de-para" do
      igual = automation([], name: "Igual")
      mais = automation([], name: "Mais")
      menos = automation([], name: "Menos")
      { "x.igual" => igual, "x.mais" => mais, "x.menos" => menos }.each { |ext, a| ExternalRef.link!(site, "ref_falsa", ext, kind: "automation", target: a) }
      ExternalRef.link!(site, "ref_falsa", "luz.lampada", kind: "entity", target: lamp)
      [ igual, mais ].each do |a|
        run = a.runs.create!(tenant: tenant, site: site, version: 1, trigger: {}, status: "done", shadow: true, started_at: 1.hour.ago)
        ShadowAction.create!(site: site, automation: a, automation_run: run, action: "command", title: "Ligar", effects: [ { "point_id" => lamp.id, "command" => "on" } ])
      end
      ref = { "x.igual" => { "runs" => 1, "effects" => [ %w[luz.lampada ligado] ] }, "x.mais" => { "runs" => 1, "effects" => [] },
              "x.menos" => { "runs" => 1, "effects" => [ %w[luz.lampada desligado], %w[outra.coisa on] ] }, "x.nova" => { "name" => "Nova", "runs" => 2, "effects" => [] } }
      report = Shadow::Compare.call(site, "ref_falsa", from: 2.hours.ago, to: Time.current, entries: ref)
      by = report.rows.index_by { |r| r["ref"] }
      expect(by.transform_values { |r| r["status"] }).to eq("x.igual" => "same", "x.mais" => "extra", "x.menos" => "missing", "x.nova" => "unmapped")
      expect(by["x.menos"]["ignored"]).to eq([ "outra.coisa" ])
      expect(by["x.mais"]["detail"]).to include("só na sombra: luz.lampada=ligado")
      expect(report.summary).to eq("same" => 1, "extra" => 1, "missing" => 1, "unmapped" => 1)
      expect(report.to_csv).to include("Igual;x.igual;Igual")
    end

    it "efeito diferente e alternar (qualquer estado)" do
      a = automation([], name: "Dif")
      ExternalRef.link!(site, "ref_falsa", "x.dif", kind: "automation", target: a)
      ExternalRef.link!(site, "ref_falsa", "luz.lampada", kind: "entity", target: lamp)
      run = a.runs.create!(tenant: tenant, site: site, version: 1, trigger: {}, status: "done", shadow: true, started_at: 1.hour.ago)
      ShadowAction.create!(site: site, automation: a, automation_run: run, action: "command", title: "x",
                           effects: [ { "point_id" => lamp.id, "command" => "set", "value" => 3.0 }, { "point_id" => lamp.id, "command" => "toggle" } ])
      ref = { "x.dif" => { "runs" => 1, "effects" => [ %w[luz.lampada ligado], %w[luz.lampada 4] ] } }
      row = Shadow::Compare.call(site, "ref_falsa", from: 2.hours.ago, to: Time.current, entries: ref).rows.first
      expect(row).to include("status" => "different", "missing" => [ "luz.lampada=4" ], "extra" => [ "luz.lampada=3" ])
    end

    it "Home Assistant: lê o diário (execuções e efeitos) e traduz o estado" do
      plugin = Integrations::HomeAssistantPlugin
      entries = [
        { "domain" => "automation", "entity_id" => "automation.a", "name" => "A", "message" => "triggered by state" },
        { "entity_id" => "switch.s", "state" => "on", "context_event_type" => "automation_triggered", "context_entity_id" => "automation.a" },
        { "entity_id" => "sensor.t", "state" => "3", "context_event_type" => "automation_triggered", "context_entity_id" => "automation.a" },
        { "entity_id" => "switch.s", "state" => "off", "context_entity_id" => "automation.a", "context_state" => "on" }
      ]
      expect(plugin.reference(nil, 1.hour.ago, Time.current, entries: entries)).to eq("automation.a" => { "name" => "A", "runs" => 1, "effects" => [ %w[switch.s on] ] })
      expect([ plugin.state_for("on", nil), plugin.state_for("start", nil), plugin.state_for("set", 2), plugin.state_for("toggle", nil) ]).to eq(%w[on active 2 *])
    end

    it "Home Assistant: busca o diário pela API só com GET e compara a cada 6 h" do
      tenant.update!(http_allow_text: "192.168.0.10")
      integration = site.integrations.create!(driver: "home_assistant", name: "HA", settings: { "url" => "http://192.168.0.10:8123" }, credentials: { "token" => "t" }.to_json)
      stub_request(:get, %r{/api/logbook/}).with(headers: { "Authorization" => "Bearer t" }).to_return(body: "[]")
      Integrations::HomeAssistantPlugin.tick(Time.zone.parse("2026-10-31 12:10"))
      expect(ShadowReport.where(site: site, source: "home_assistant").count).to eq(1)
      Integrations::HomeAssistantPlugin.tick(Time.zone.parse("2026-10-31 12:11"))
      expect(ShadowReport.count).to eq(1)
      expect(a_request(:post, /.*/)).not_to have_been_made
      expect(integration.reload.status).not_to eq("error")
    end
  end

  describe "importação do Home Assistant (arquivos sintéticos)" do
    let(:integration) { site.integrations.create!(driver: "tuya", name: "Nuvem", inventory: found.to_json) }
    let(:found) do
      [ { "id" => "dev2", "kind" => "tuya_cloud", "name" => "Tomada", "room" => "Quarto", "points" => [ { "name" => "Tomada", "capability" => "onoff",
                                                                                                     "writable" => true, "address" => { "code" => "switch_1" } } ] } ]
    end
    let(:files) do
      {
        "area_registry" => { "data" => { "areas" => [ { "id" => "sala", "name" => "Sala" }, { "id" => "quarto", "name" => "Quarto" } ] } },
        "device_registry" => { "data" => { "devices" => [ { "id" => "d1", "identifiers" => [ %w[localtuya local_dev1] ], "area_id" => "sala", "name" => "Ap" },
                                                          { "id" => "d2", "identifiers" => [ %w[tuya dev2] ], "area_id" => "quarto", "name" => "Tomada" } ] } },
        "entity_registry" => { "data" => { "entities" => [
          { "id" => "aaaabbbbccccdddd0000111122223333", "entity_id" => "switch.ap", "unique_id" => "local_dev1_1", "device_id" => "d1", "platform" => "localtuya" },
          { "id" => "e2", "entity_id" => "switch.tomada", "unique_id" => "tuya.dev2switch_1", "device_id" => "d2", "platform" => "tuya" },
          { "id" => "e3", "entity_id" => "automation.liga", "unique_id" => "100", "platform" => "automation" }
        ] } },
        "states" => [
          { "entity_id" => "automation.liga", "state" => "on", "attributes" => {} },
          { "entity_id" => "input_boolean.modo", "state" => "off", "attributes" => { "friendly_name" => "Modo" } },
          { "entity_id" => "timer.rega", "state" => "idle", "attributes" => { "friendly_name" => "Rega", "duration" => "0:05:00" } },
          { "entity_id" => "input_select.cor", "state" => "a", "attributes" => { "friendly_name" => "Cor", "options" => %w[a b] } },
          { "entity_id" => "switch.grupo", "state" => "off", "attributes" => { "friendly_name" => "Grupo", "entity_id" => %w[switch.ap switch.tomada] } },
          { "entity_id" => "scene.noite", "state" => "x", "attributes" => { "id" => "1" } }
        ],
        "scenes" => "- id: '1'\n  name: Noite\n  entities:\n    switch.ap: 'off'\n    switch.sumiu: 'on'\n",
        "scripts" => "apagar:\n  alias: Apagar\n  sequence:\n    - action: switch.turn_off\n      target: { entity_id: switch.ap }\n",
        "automations" => <<~YAML
          - id: '100'
            alias: Liga
            triggers: [ { trigger: state, entity_id: input_boolean.modo, to: 'on' } ]
            actions:
              - action: switch.turn_on
                target: { entity_id: switch.tomada }
              - action: script.apagar
              - action: scene.turn_on
                target: { entity_id: scene.noite }
              - type: turn_on
                device_id: d1
                entity_id: aaaabbbbccccdddd0000111122223333
                domain: switch
          - id: '200'
            alias: Sem par
            triggers: [ { trigger: state, entity_id: switch.inexistente } ]
            actions: [ { action: shell_command.x } ]
        YAML
      }
    end

    before do
      allow(Integrations::TuyaPlugin).to receive(:refresh)
      create(:device, site: site, driver: "tuya_local", external_id: "dev1", name: "Ap local").tap do |d|
        create(:point, site: site, device: d, name: "Ap", capability: "onoff", writable: true, address: { "dps" => "1" })
      end
      integration
    end

    it "traz áreas, aparelhos, de-para, helpers, cenas, scripts e automações em sombra" do
      r = Integrations::HomeAssistantImport.call(site, files.transform_values { |v| v.is_a?(String) ? v : v.to_json })
      expect(site.areas.pluck(:name)).to include("Sala", "Quarto")
      expect(r.devices_added).to eq(1)
      expect(site.devices.find_by(external_id: "dev2").area.name).to eq("Quarto")
      expect(site.devices.find_by(external_id: "dev1").area.name).to eq("Sala")
      expect(ExternalRef.map_for(site, "home_assistant", "Point").keys).to include("switch.ap", "switch.tomada", "input_boolean.modo", "timer.rega", "input_select.cor", "switch.grupo")
      expect(r.helpers).to eq(4)
      expect(site.scenes.find_by!(name: "Noite")).to have_attributes(shadow: true, items: [ hash_including("command" => "off") ])
      expect(r.scenes.first["lost"]).to eq([ "switch.sumiu" ])
      liga = site.automations.find_by!(name: "Liga")
      expect(liga).to have_attributes(shadow: true, enabled: true, version: 1)
      expect(liga.definition["actions"].pluck("type")).to eq(%w[command command scene command])
      expect(site.scripts.find_by!(name: "Apagar")).to have_attributes(shadow: true)
      items = r.items.index_by { |i| i["name"] }
      expect(items["Liga"]["lossless"]).to be(true)
      expect(items["Sem par"]).to include("lossless" => false)
      expect(site.automations.find_by!(name: "Sem par")).to have_attributes(enabled: false, shadow: true)
      expect(Automation.where(site: site, enabled: true, shadow: false)).to be_empty

      again = Integrations::HomeAssistantImport.call(site, files.transform_values { |v| v.is_a?(String) ? v : v.to_json })
      expect([ again.items.size, again.helpers, site.automations.count ]).to eq([ 0, 0, 2 ])
      expect(Command.count).to eq(0)
    end
  end
end
