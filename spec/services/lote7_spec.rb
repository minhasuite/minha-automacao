require "rails_helper"

# Lote 7 (migração em sombra, F10): o Jinja que segurava os rascunhos vira
# Liquid/expressão, as ações do HA sem par ganham equivalente genérico
# ("Anotar", "Recarregar integração", "Chamar HTTP" pelo rest_command) e o
# importador traz etiquetas e os sensores template da tela do HA. Tudo
# sintético; nada sai para a rede.
RSpec.describe "Lote 7: zerar os rascunhos da migração" do
  include ActiveJob::TestHelper

  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, name: "Local") }
  let(:device) { create(:device, site: site, driver: "virtual", name: "Aparelho") }

  around { |ex| ActsAsTenant.with_tenant(tenant) { travel_to(Time.zone.parse("2026-10-31 12:00")) { ex.run } } }

  def point(name, key, capability: "onoff", **attrs)
    create(:point, site: site, device: device, name: name, key: key, capability: capability, data_type: Point::CAPABILITIES[capability], writable: true, **attrs)
  end

  def run!(actions, shadow: false)
    a = Automation.create!(site: site, name: "A #{SecureRandom.hex(3)}", kind: "automation", mode: "parallel", shadow: shadow)
    a.publish!({ "triggers" => [ { "type" => "manual" } ], "conditions" => [], "actions" => actions })
    a.fire!({ "type" => "manual", "title" => "Teste" }, skip_conditions: true)
  end

  describe "Blueprints::Jinja (Lote 7)" do
    let(:jinja) do
      Blueprints::Jinja.new(->(e) { e.tr(".", "_") }, areas: { "sala_tv" => "Sala TV", "cozinha" => "Cozinha" },
                                                     labels: { "iluminacao" => "Iluminação" }, entries: { "E1" => "tuya" }).tap { |j| j.consts = { "entrada" => "E1" } }
    end

    it "traduz data e hora, atributo, teste, dicionário, consulta e integração para a expressão" do
      {
        "{{ ((now() - states.binary_sensor.porta.last_changed).total_seconds() / 60) | round(0) | int }}" => "round(((timestamp - [[binary_sensor_porta]].changed_at) / 60), 0)",
        "{{ now() - timedelta(minutes=2, seconds=5) }}" => "(timestamp - 125)",
        "{{ now().timestamp() > as_timestamp(ev.start) }}" => "timestamp > to_timestamp(ev.start)",
        "{{ states.switch.a.state }}" => "[[switch_a]]",
        "{{ state_attr('calendar.b', 'all_day') == true }}" => "[[calendar_b]].attrs.all_day = true",
        "{{ state_attr('calendar.b', 'start') is not none }}" => "defined('[[calendar_b]].attrs.start')",
        "{{ x is defined and x is none }}" => "(defined('x') and not(defined('x')))",
        "{{ {'a': 'A', 'b': \"it's\"}.get(m, 'X') }}" => "if(m = 'a', 'A', if(m = 'b', \"it's\", 'X'))",
        "{{ {'a': 1}[m] }}" => "if(m = 'a', 1, '')",
        "{{ lista[1] }}" => "lista.1",
        "{{ n | default(3) }}" => "if(defined('n'), n, 3)",
        "{{ trigger.to_state.attributes.event_type == 'click' }}" => "trigger.value = 'click'",
        "{{ label_entities('iluminacao') | select('in', area_entities('cozinha') + area_entities('sala_tv')) | select('is_state', 'on') | list | count > 0 }}" =>
          "count_points('tag=Iluminação area=\"Cozinha,Sala TV\" state=on') > 0",
        "{{ states | selectattr('state', 'eq', 'unavailable') | list | count }}" => "count_points('quality=unavailable')",
        "{{ states.switch | reject('is_state', 'unavailable') | list | length }}" => "count_points('capability=onoff quality=good,stale,error')",
        "{{ integration_entities('tuya') | select('is_state', 'off') | list | count }}" => "count_points('integration=tuya_cloud state=off')",
        "{{ config_entry_attr(entrada, 'state') != 'loaded' }}" => "if(integration_ok('tuya'), 'loaded', 'not_loaded') != 'loaded'"
      }.each { |src, out| expect(jinja.expr(src)).to eq(out), src }
      [ "{{ states.switch.a }}", "{{ x is match('a') }}", "{{ integration_entities('zzz') | list | count }}", "{{ label_entities('x') | select('match', 'a') | list | count }}",
        "{{ config_entry_attr('nada', 'state') }}", "{{ timedelta(minutes=x) }}", "{{ as_timestamp(now()) }}x", "{{ x[-1] }}" ].each { |src| expect(jinja.expr(src)).to be_nil, src }
    end

    it "traduz {% set/if/for %} e namespace para Liquid que roda com as variáveis do bloco" do
      out = jinja.text("{% set ns = namespace(n=0, l=[]) %}{% for nome, d in agendas.items() %}{% set ns.n = ns.n + (d.eventos | count) %}" \
                       "{% for ev in d.eventos if ev.dia > 1 %}{% set ns.l = ns.l + [nome ~ ': ' ~ ev.titulo] %}{% endfor %}{% endfor %}" \
                       "{{ ns.n }} | {{ ns.l | join(', ') if ns.l else 'nenhum' }}")
      expect(out).to start_with("{% assign ns_n = '0' | calc %}{% assign ns_l = \"\" | split: \",\" %}{% for _j1 in agendas %}")
      ctx = Automations::Context.new(site: site, vars: { "agendas" => { "casa" => { "eventos" => [ { "dia" => 2, "titulo" => "Festa" }, { "dia" => 1, "titulo" => "Ontem" } ] },
                                                                        "trabalho" => { "eventos" => [] } } })
      expect(ctx.render(out)).to eq("2 | casa: Festa")
      ctx2 = Automations::Context.new(site: site, vars: { "a" => "", "b" => 2, "lista" => [] })
      expect(ctx2.render(jinja.text("{% if a %}A{% elif b > 1 %}B{% else %}C{% endif %}/{% if not lista %}vazia{% endif %}"))).to eq("B/vazia")
      expect(ctx2.render(jinja.text("{% for x in ['p', 'q'] %}{{ x }}{% endfor %} {{ 'a_b_c'.split('_')[1] }} {{ 'abc'[:2] }}"))).to eq("pq b ab")
      expect(jinja.text("Offline desde {{ as_local(states.binary_sensor.hub.last_changed).strftime('%H:%M') }} {{ state_attr('sensor.x', 'nome') }}"))
        .to eq("Offline desde {{ points[\"[[binary_sensor_hub]]\"].changed_at | date: \"%H:%M\" }} {{ points[\"[[sensor_x]]\"].attrs.nome }}")
      [ "{% if a %}x", "{% endfor %}", "{% for s in states.switch %}{% endfor %}", "{% set x.y = 1 %}", "{% macro m() %}{% endmacro %}",
        "{% elif a %}", "{% for a, b in lista %}{% endfor %}" ].each { |src| expect(jinja.text(src)).to be_nil, src }
    end
  end

  describe "contexto: segundos desde a mudança, defined, integration_ok e to_timestamp" do
    it "calcula com o ponto, as variáveis e as integrações do local" do
      porta = point("Porta", "porta", changed_at: 10.minutes.ago, value: true)
      site.integrations.create!(driver: "tuya", name: "Nuvem", status: "ok")
      ctx = Automations::Context.new(site: site, vars: { "x" => { "y" => 1 } })
      expect(ctx.calc("round((timestamp - porta.changed_at) / 60)")).to eq(10)
      expect([ ctx.calc("defined('x.y')"), ctx.calc("defined('x.z')"), ctx.calc("defined('porta')"), ctx.calc("defined('nada')") ]).to eq([ true, false, true, false ])
      expect([ ctx.calc("integration_ok('tuya')"), ctx.calc("integration_ok('alexa')") ]).to eq([ true, false ])
      expect(ctx.calc("to_timestamp('2026-10-31T09:00:00-03:00')")).to eq(Time.zone.parse("2026-10-31T12:00:00Z").to_i)
      expect([ Automations::Expr.timestamp("x"), Automations::Expr.timestamp(5), Automations::Expr.timestamp(Time.current) ]).to eq([ 0, 5, Time.current.to_i ])
      expect(porta.reload.value).to be(true)
    end
  end

  describe "importar automações do HA (Lote 7)" do
    let(:rest) { { "ping" => { "url" => "{{ url }}", "method" => "post", "payload" => "{{ corpo }}", "content_type" => "text/plain", "timeout" => 15 } } }

    def convert(yaml, **opts)
      doc = YAML.safe_load(yaml)
      Blueprints::HaImport.new("", nil, entities: true, **opts).convert(Blueprints::HaImport.as_blueprint("automation", "X", doc))
    end

    it "espera por template, valor de helper por texto, anotar, rest_command e recarregar integração" do
      attrs = convert(<<~YAML, rest_commands: rest, entries: { "E1" => "alexa_media" })
        triggers: [ { trigger: time, at: '08:00' } ]
        variables: { entrada: E1 }
        actions:
          - delay: { minutes: '{{ 5 * repeat.index }}', seconds: 30 }
          - delay: '{{ espera }}'
          - action: timer.start
            target: { entity_id: timer.rega }
            data: { duration: '{{ restante | int }}' }
          - action: logbook.log
            data: { name: Ventilador, message: "ligou às {{ now().strftime('%H:%M') }}" }
          - action: rest_command.ping
            continue_on_error: true
            data: { url: "https://exemplo.test/{{ 'a' }}", corpo: "disco {{ n }}%", vezes: 2 }
          - action: homeassistant.reload_config_entry
            data: { entry_id: '{{ entrada }}' }
          - action: localtuya.reload
          - action: rest_command.sem_definicao
      YAML
      acts = attrs["definition"]["actions"].drop(1) # a variável constante vem primeiro
      expect(attrs["definition"]["actions"].first).to eq("type" => "set", "var" => "entrada", "value" => "E1")
      expect(acts[0..1]).to eq([ { "type" => "wait", "expr" => "((5 * repeat_index)) * 60 + (30) * 1" }, { "type" => "wait", "expr" => "espera" } ])
      expect(acts[2]).to include("type" => "command", "command" => "start", "value" => "{{ restante | floor }}")
      expect(acts[3]).to eq("type" => "trace_note", "message" => "Ventilador: ligou às {{ now | date: \"%H:%M\" }}")
      expect(acts[4..6].pluck("var")).to eq(%w[url corpo vezes])
      expect(acts[7]).to eq("type" => "http", "method" => "POST", "url" => "{{ url }}", "body" => "{{ corpo }}", "headers" => "Content-Type: text/plain",
                            "timeout" => 15, "continue_on_error" => true)
      expect(acts[8..9]).to eq([ { "type" => "integration_reload", "integration" => "alexa" }, { "type" => "integration_reload", "integration" => "tuya" } ])
      expect(attrs["unsupported"]).to eq([ "ação rest_command.sem_definicao" ])
    end

    it "plugin falso: integração nova do HA entra só pelo de-para e pelo registro de plugins" do
      fake = Class.new(Integrations::Plugin) { describe key: "falsa", title: "Falsa", icon: "x", description: "teste" }
      stub_const("Integrations::FalsaPlugin", fake)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[FalsaPlugin])
      stub_const("Blueprints::HaImport::HA_PLUGINS", Blueprints::HaImport::HA_PLUGINS.merge("dominio_falso" => "falsa"))
      attrs = convert("triggers: [ { trigger: time, at: '08:00' } ]\nactions: [ { action: dominio_falso.reload } ]")
      expect(attrs["definition"]["actions"]).to eq([ { "type" => "integration_reload", "integration" => "falsa" } ])
      expect(Automations::Dsl.errors(attrs["definition"], site)).to be_empty
      expect(Automations::ActionTypes::IntegrationReloadAction.rules("integration" => "nao_existe")).to include(a_string_including("falsa"))
    end
  end

  describe "ações novas" do
    it "anotar fica no trace e roda em sombra; recarregar integração vai para a fila (e em sombra é segurada)" do
      integration = site.integrations.create!(driver: "tuya", name: "Nuvem", status: "ok")
      run = run!([ { "type" => "trace_note", "message" => "oi {{ 1 | plus: 1 }}" }, { "type" => "integration_reload", "integration" => "tuya" } ])
      expect(run.status).to eq("done")
      expect(run.steps.pluck("detail")).to include("oi 2", "1 na fila")
      expect(integration.reload.status).to eq("syncing")
      expect(enqueued_jobs.map { |j| j["job_class"] }).to include("SyncIntegrationJob")

      clear_enqueued_jobs
      integration.update_columns(status: "ok") # rubocop:disable Rails/SkipsModelValidations
      shadow = run!([ { "type" => "trace_note", "message" => "sombra" }, { "type" => "integration_reload", "integration" => "tuya" } ], shadow: true)
      expect(shadow.steps.pluck("detail")).to include("sombra")
      expect(ShadowAction.where(automation_run_id: shadow.id).pluck(:action)).to eq([ "integration_reload" ])
      expect(enqueued_jobs).to be_empty
      expect(integration.reload.status).to eq("ok")

      none = run!([ { "type" => "integration_reload", "integration" => "alexa" } ])
      expect(none.status).to eq("failed")
    end

    it "valor do comando por texto Liquid (helper do HA com template)" do
      nivel = point("Nível", "nivel", capability: "setpoint", value: 0)
      run = run!([ { "type" => "set", "var" => "n", "expr" => "21 * 2" }, { "type" => "command", "point" => nivel.id, "command" => "set", "value" => "{{ n }}" } ])
      expect(run.status).to eq("done")
      expect(Command.last).to have_attributes(point_id: nivel.id, value: "42")
      expect(Automations::Dsl.errors({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "command", "point" => nivel.id, "command" => "set", "value" => "{{ n" } ] }, site))
        .to include(a_string_including("texto inválido"))
    end
  end

  describe "importação da instalação (Lote 7)" do
    let(:integration) { site.integrations.create!(driver: "tuya", name: "Nuvem", status: "ok", inventory: found.to_json) }
    let(:found) do
      [ { "id" => "dev1", "kind" => "tuya_cloud", "name" => "Luz da cozinha", "room" => "Cozinha", "points" => [ { "name" => "Luz", "capability" => "onoff", "writable" => true, "address" => { "code" => "switch_1" } } ] },
        { "id" => "dev2", "kind" => "tuya_cloud", "name" => "Luz da sala", "room" => "Sala", "points" => [ { "name" => "Luz", "capability" => "onoff", "writable" => true, "address" => { "code" => "switch_1" } } ] } ]
    end
    let(:files) do
      {
        "area_registry" => { "data" => { "areas" => [ { "id" => "cozinha", "name" => "Cozinha" }, { "id" => "sala_tv", "name" => "Sala TV" } ] } },
        "label_registry" => { "data" => { "labels" => [ { "label_id" => "iluminacao", "name" => "Iluminação" } ] } },
        "device_registry" => { "data" => { "devices" => [ { "id" => "d1", "identifiers" => [ %w[tuya dev1] ], "area_id" => "cozinha", "name" => "Luz" },
                                                          { "id" => "d2", "identifiers" => [ %w[tuya dev2] ], "area_id" => "sala_tv", "name" => "Luz" } ] } },
        "entity_registry" => { "data" => { "entities" => [
          { "id" => "e1", "entity_id" => "switch.luz_cozinha", "unique_id" => "tuya.dev1switch_1", "device_id" => "d1", "platform" => "tuya", "labels" => [ "iluminacao" ] },
          { "id" => "e2", "entity_id" => "switch.luz_sala", "unique_id" => "tuya.dev2switch_1", "device_id" => "d2", "platform" => "tuya", "labels" => [ "iluminacao" ] },
          { "id" => "e3", "entity_id" => "binary_sensor.luzes_cozinha", "config_entry_id" => "t1", "platform" => "template" },
          { "id" => "e4", "entity_id" => "automation.aviso", "unique_id" => "300", "platform" => "automation" }
        ] } },
        "config_entries" => { "data" => { "entries" => [
          { "entry_id" => "t1", "domain" => "template", "title" => "Luzes acesas Cozinha",
            "options" => { "template_type" => "binary_sensor", "name" => "Luzes acesas Cozinha",
                           "state" => "{{ label_entities('iluminacao') | select('in', area_entities('cozinha')) | select('is_state', 'on') | list | count > 0 }}" } },
          { "entry_id" => "t2", "domain" => "template", "title" => "Sem tradução", "options" => { "template_type" => "sensor", "state" => "{{ states.sensor | map(attribute='x') }}" } },
          { "entry_id" => "tu", "domain" => "tuya", "title" => "Tuya" }
        ] } },
        "states" => [ { "entity_id" => "automation.aviso", "state" => "on", "attributes" => {} } ],
        "configuration" => "automation: !include automations.yaml\nrest_command:\n  ping:\n    url: \"{{ url }}\"\n    method: post\n",
        "automations" => <<~YAML
          - id: '300'
            alias: Aviso
            triggers: [ { trigger: state, entity_id: switch.luz_cozinha, to: 'on' } ]
            actions:
              - delay: { minutes: '{{ 2 * 3 }}' }
              - action: rest_command.ping
                data: { url: "https://exemplo.test" }
              - action: logbook.log
                data: { message: "{{ states.switch.luz_cozinha.last_changed }}" }
        YAML
      }
    end

    before do
      allow(Integrations::TuyaPlugin).to receive(:refresh)
      integration
    end

    it "etiquetas, sensor template da tela do HA como sensor calculado e item refeito no lugar" do
      json = files.transform_values { |v| v.is_a?(String) ? v : v.to_json }
      r = Integrations::HomeAssistantImport.call(site, json)
      expect(r.tags).to eq(2)
      expect(Tagging.joins(:tag).where(tags: { name: "iluminação" }).count).to eq(2)
      luzes = Point.find(ExternalRef.map_for(site, "home_assistant", "Point")["binary_sensor.luzes_cozinha"])
      expect(luzes).to have_attributes(helper: "template", capability: "onoff")
      expect(luzes.address["expr"]).to eq("count_points('tag=Iluminação area=Cozinha state=on') > 0")
      expect(r.helpers_skipped).to include(a_string_including("template sem tradução"))

      cozinha = site.points.find_by!(id: ExternalRef.map_for(site, "home_assistant", "Point")["switch.luz_cozinha"])
      cozinha.report!(true)
      expect(luzes.reload.value).to be(true)

      aviso = site.automations.find_by!(name: "Aviso")
      expect(aviso).to have_attributes(shadow: true, enabled: true, version: 1)
      expect(aviso.definition["actions"].pluck("type")).to eq(%w[wait set http trace_note])
      expect(aviso.definition["actions"].last["message"]).to eq("{{ points[\"#{cozinha.key}\"].changed_at }}")
      expect(r.items.first["lossless"]).to be(true)

      # Com perda (blueprint anotado): a próxima importação refaz no mesmo registro.
      aviso.blueprint.update_columns(unsupported: [ "algo" ]) # rubocop:disable Rails/SkipsModelValidations
      again = Integrations::HomeAssistantImport.call(site, json)
      expect(again.items.map { |i| i["name"] }).to eq([ "Aviso" ])
      expect(site.automations.where(name: "Aviso").pluck(:id)).to eq([ aviso.id ])
      expect(aviso.reload).to have_attributes(version: 2, shadow: true, enabled: true, draft: nil)
      expect(Integrations::HomeAssistantImport.call(site, json).items).to be_empty

      # A versão publicada ficou inválida (o ponto sumiu) e a entrada nova não tem par: o rascunho é refeito mesmo assim.
      aviso.update_columns(definition: aviso.definition.merge("actions" => [ { "type" => "command", "point" => SecureRandom.uuid, "command" => "on" } ])) # rubocop:disable Rails/SkipsModelValidations
      aviso.blueprint.update_columns(unsupported: [ "algo" ]) # rubocop:disable Rails/SkipsModelValidations
      json["automations"] = json["automations"].sub("switch.luz_cozinha, to: 'on'", "switch.sem_par, to: 'on'")
      last = Integrations::HomeAssistantImport.call(site, json)
      expect(last.items.first["notes"]).to include("sem de-para: switch.sem_par", a_string_including("rascunho: não publicou (gatilhos 1"))
      expect(aviso.reload).to have_attributes(version: 2, enabled: false)
      expect(aviso.draft).to be_present
      expect(Command.count).to eq(0)
    end
  end
end
