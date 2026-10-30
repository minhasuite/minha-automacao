require "rails_helper"

# Lote 5 (paridade HA): o importador fecha os buracos que impediam migrar as
# automações (gatilho e ação de aparelho, início do sistema, horário vindo de
# ponto, cena, script, id do gatilho) e traduz o Jinja comum para expressão e
# Liquid. Nada sai para a rede.
RSpec.describe "Lote 5: importador do HA, Jinja e gatilhos novos" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, name: "Local") }
  let(:device) { create(:device, site: site, driver: "virtual") }

  around { |ex| ActsAsTenant.with_tenant(tenant) { travel_to(Time.zone.parse("2026-10-30 12:00")) { ex.run } } }

  def point(name, capability: "onoff", **attrs)
    create(:point, site: site, device: device, name: name, capability: capability, data_type: Point::CAPABILITIES[capability], writable: true, **attrs)
  end

  def build(definition, enabled: true)
    a = Automation.create!(site: site, name: "Teste #{SecureRandom.hex(3)}", kind: "automation", mode: "parallel")
    a.publish!(definition)
    a.update!(enabled: enabled)
    a
  end

  describe "Blueprints::Jinja" do
    let(:jinja) { Blueprints::Jinja.new(->(e) { e.tr(".", "_") unless e.start_with?("sun.") }) }

    it "traduz expressões comuns para o dentaku" do
      {
        "{{ is_state('switch.a', 'on') }}" => "[[switch_a]] = true",
        "{{ states('sensor.t') | float(0) > 20 and now().hour >= 22 }}" => "([[sensor_t]] > 20 and hour >= 22)",
        "{{ states('switch.a') != states('switch.b') }}" => "[[switch_a]] != [[switch_b]]",
        "{{ states('switch.a') == 'off' }}" => "[[switch_a]] = false",
        "{{ trigger.id == 'botao' }}" => "trigger.id = 'botao'",
        "{{ trigger.to_state.state == 'on' }}" => "trigger.value = 'on'",
        "{{ canal in ['a', 'b'] }}" => "(canal = 'a' or canal = 'b')",
        "{{ x not in ['a'] }}" => "not(x = 'a')",
        "{{ not ok }}" => "not(ok)",
        "{{ 'x' if n > 1 else 'y' }}" => "if(n > 1, 'x', 'y')",
        "{{ iif(n > 1, 2, 3) }}" => "if(n > 1, 2, 3)",
        "{{ (r.kwh * 2) | round(2) }}" => "round((r.kwh * 2), 2)",
        "{{ 5 * (2 ** (repeat.index - 1)) }}" => "(5 * (2 ^ (repeat_index - 1)))",
        "{{ lista | count > 0 }}" => "lista.count > 0",
        "{{ as_timestamp(now()) - 60 }}" => "(timestamp - 60)",
        "{{ now().weekday() == 0 }}" => "((weekday + 6) % 7) = 0",
        "{{ trigger.json.canal }}" => "trigger.data.canal",
        "{{ -n + min(1, 2) }}" => "(-n + min(1, 2))",
        "{{ true }}" => "true"
      }.each { |src, out| expect(jinja.expr(src)).to eq(out), src }
    end

    it "traduz texto para Liquid e calcula o resto com | calc" do
      expect(jinja.text("Às {{ now().strftime('%H:%M') }}: {{ states('sensor.t') }} e {{ msg | trim }}"))
        .to eq("Às {{ now | date: \"%H:%M\" }}: {{ points[\"[[sensor_t]]\"].text }} e {{ msg | strip }}")
      expect(jinja.text("Há {{ 5 * repeat.index }} min ({{ repeat.index }}) {{ 'a' ~ x }}")).to eq("Há {{ \"(5 * repeat_index)\" | calc }} min ({{ repeat.index }}) a{{ x }}")
      expect(jinja.text("{{ lista | join(', ') }} {{ x | default('-') }} {{ n | int }} {{ now().isoformat() }}"))
        .to eq("{{ lista | join: \", \" }} {{ x | default: \"-\" }} {{ n | floor }} {{ now | date: \"%Y-%m-%dT%H:%M:%S%:z\" }}")
      expect(jinja.text("sem template")).to eq("sem template")
    end

    it "devolve nil no que não cobre" do
      [ "{{ state_attr('a.b', 'c') }}", "{{ x is defined }}", "{{ states.switch.a.last_changed }}", "{{ is_state('sun.sun', 'below_horizon') }}",
        "{{ {'a': 1}.get(x) }}", "{{ x[0] }}", "texto {{ a }}", "{{ now() }}", "{{ 'a' ~ 'b' }}", "{{ '%02d' % n }}", "{{ f(a=1) }}", "{{ x | from_json }}" ]
        .each { |src| expect(jinja.expr(src)).to be_nil, src }
      expect(jinja.text("{% if a %}x{% endif %}")).to be_nil
      expect(jinja.text("{{ x | regex_replace('a', 'b') }}")).to eq("{{ \"x\" | calc }}").or be_nil
    end
  end

  describe "importar do HA (G32): o que antes não virava blueprint" do
    let(:yaml) do
      <<~YAML
        - alias: Aparelho espelha
          triggers:
            - { trigger: device, type: turned_on, device_id: ebbe59c2fbd7063b22e7aa963e4709d8, entity_id: 33e341cd695f9f662e5cb9df056c26bf, domain: switch }
            - { trigger: device, type: no_motion, device_id: 11112222333344445555666677778888, entity_id: aaaabbbbccccddddeeeeffff00001111, domain: binary_sensor, for: { minutes: 1 }, id: parado }
          conditions:
            - { condition: device, type: is_off, device_id: 9f0eb4ca4699adb3eacaaf1365d6525e, entity_id: 7e780edc4a7889218453ed03a30494ba, domain: light }
            - { condition: trigger, id: parado }
          actions:
            - { type: turn_on, device_id: 5078843b2aa5c9bb02ed526af3fe2937, entity_id: 7e780edc4a7889218453ed03a30494ba, domain: light }
            - action: light.turn_off
              target: { device_id: [ 8f3e19d215c7fd06e249d331a0f4de72 ] }
        - alias: Início e horários
          initial_state: true
          triggers:
            - { trigger: homeassistant, event: start }
            - { trigger: time, at: input_datetime.acordar, id: hora }
            - { trigger: time, at: 32400, weekday: [ mon, fri ] }
            - { trigger: time, at: [ "07:00:00", "08:30:00" ] }
            - { trigger: calendar, event: start, offset: "-0:15:0", entity_id: calendar.trabalho }
            - { trigger: state, entity_id: [ switch.a, switch.b ], to: "on", id: botao }
          conditions:
            - "{{ is_state('switch.a', 'on') and now().hour >= 6 }}"
            - { condition: time, before: 18000 }
            - { condition: time, weekday: [ sat ] }
            - { condition: sun, after: sunset, after_offset: "-00:30:00" }
            - { condition: or, conditions: [ { condition: state, entity_id: [ switch.a, switch.b ], state: "off" } ] }
          variables:
            limite: 30
          actions:
            - delay: { seconds: 90 }
            - action: scene.turn_on
              target: { entity_id: scene.noite }
            - action: script.boa_noite
              data: { modo: rapido }
            - action: script.turn_on
              target: { entity_id: script.boa_noite }
            - action: switch.turn_{{ trigger.to_state.state }}
              target: { entity_id: switch.b }
            - action: input_number.set_value
              target: { entity_id: input_number.nivel }
              data: { value: 3 }
            - action: notify.mobile_app_x
              data: { title: "Hora {{ now().strftime('%H:%M') }}", message: "Agora {{ states('sensor.t') }} °C, {{ states('sensor.t') | float(0) + 1 }}" }
            - variables: { alto: "{{ states('sensor.t') | float(0) > limite }}", frase: "Temp {{ states('sensor.t') }}" }
            - event: casa_pronta
              event_data: { quem: "{{ trigger.id }}" }
            - wait_for_trigger: [ { trigger: event, event_type: casa_ok } ]
              timeout: "00:02:00"
            - wait_template: "{{ is_state('switch.b', 'off') }}"
            - action: calendar.get_events
              target: { entity_id: calendar.trabalho }
              data: { duration: { hours: 24 } }
              response_variable: agenda
            - action: weather.get_forecasts
              target: { entity_id: weather.casa }
              data: { type: hourly }
              response_variable: previsao
            - action: ai_task.generate_data
              data: { task_name: x, instructions: "Resuma {{ frase }}" }
              response_variable: ia
      YAML
    end

    it "aparelho, início, horário por ponto, cena, script, espelho, helper, evento, agenda, clima e IA viram a DSL" do
      a, b = Blueprints::HaImport.import(yaml)
      expect(a["unsupported"]).to eq([])
      keys = a["inputs"].pluck("key")
      expect(keys).to eq(%w[aparelho_33e341cd aparelho_aaaabbbb aparelho_7e780edc aparelho_8f3e19d2])
      expect(a["inputs"].find { |i| i["key"] == "aparelho_aaaabbbb" }).to include("label" => "Aparelho do HA aaaabbbb (binary_sensor)")
      d = a["definition"]
      expect(d["triggers"]).to eq([ { "type" => "state", "point" => { "!input" => "aparelho_33e341cd" }, "to" => true },
                                    { "type" => "state", "point" => { "!input" => "aparelho_aaaabbbb" }, "to" => false, "for" => "1m", "id" => "parado" } ])
      expect(d["conditions"]).to eq([ { "type" => "state", "point" => { "!input" => "aparelho_7e780edc" }, "is" => false },
                                      { "type" => "expr", "expr" => "trigger.id = 'parado'" } ])
      expect(d["actions"]).to eq([ { "type" => "command", "point" => { "!input" => "aparelho_7e780edc" }, "command" => "on" },
                                   { "type" => "command", "point" => { "!input" => "aparelho_8f3e19d2" }, "command" => "off" } ])

      expect(b["unsupported"]).to eq([])
      t = b["definition"]["triggers"]
      expect(t[0]).to eq("type" => "event", "event" => "system_started")
      expect(t[1]).to eq("type" => "time", "at_point" => { "!input" => "input_datetime_acordar" }, "id" => "hora")
      expect(t[2..4]).to eq([ { "type" => "time", "at" => "09:00", "days" => [ 1, 5 ] }, { "type" => "time", "at" => "07:00" }, { "type" => "time", "at" => "08:30" } ])
      expect(t[5]).to eq("type" => "calendar", "point" => { "!input" => "calendar_trabalho" }, "event" => "start", "offset" => "-15m")
      expect(t[6..]).to eq([ { "type" => "state", "point" => { "!input" => "switch_a" }, "to" => true, "id" => "botao" },
                             { "type" => "state", "point" => { "!input" => "switch_b" }, "to" => true, "id" => "botao" } ])
      c = b["definition"]["conditions"]
      expect(c[0]).to eq("type" => "expr", "expr" => "([[switch_a]] = true and hour >= 6)")
      expect(c[1]).to eq("type" => "time", "before" => "05:00")
      expect(c[2]).to eq("type" => "time", "after" => "00:00", "days" => [ 6 ])
      expect(c[3]).to eq("type" => "sun", "after" => "sunset", "after_offset" => "-30m")
      expect(c[4]["conditions"].sole).to eq("type" => "and", "conditions" => [ { "type" => "state", "point" => { "!input" => "switch_a" }, "is" => false },
                                                                                { "type" => "state", "point" => { "!input" => "switch_b" }, "is" => false } ])
      acts = b["definition"]["actions"]
      expect(acts.pluck("type")).to eq(%w[set wait scene command command if command notify set set fire_event wait_event wait_for calendar_events weather_forecast ai_task])
      expect(acts[0]).to eq("type" => "set", "var" => "limite", "expr" => "30")
      expect(acts[2]).to eq("type" => "scene", "scene" => { "!input" => "scene_noite" })
      expect(acts[3]).to eq("type" => "command", "point" => { "!input" => "script_boa_noite" }, "command" => "run", "value" => { "modo" => "rapido" })
      expect(acts[5]["then"]).to eq([ { "type" => "command", "point" => { "!input" => "switch_b" }, "command" => "on" } ])
      expect(acts[6]).to include("command" => "set", "value" => 3)
      expect(acts[7]["message"]).to eq("Agora {{ points[\"[[sensor_t]]\"].text }} °C, {{ \"([[sensor_t]] + 1)\" | calc }}")
      expect(acts[8]).to eq("type" => "set", "var" => "alto", "expr" => "[[sensor_t]] > limite")
      expect(acts[9]).to eq("type" => "set", "var" => "frase", "value" => "Temp {{ points[\"[[sensor_t]]\"].text }}")
      expect(acts[10]).to eq("type" => "fire_event", "event" => "casa_pronta", "data" => { "quem" => "{{ trigger.id }}" })
      expect(acts[11]).to eq("type" => "wait_event", "event" => "casa_ok", "timeout" => "2m", "continue_on_timeout" => true)
      expect(acts[13]).to include("within" => "24h", "response_variable" => "agenda")
      expect(acts[14]).to include("kind" => "hourly", "response_variable" => "previsao")
      expect(acts[15]).to eq("type" => "ai_task", "prompt" => "Resuma {{ frase }}", "response_variable" => "ia")
      expect(b["inputs"].find { |i| i["key"] == "scene_noite" }).to include("type" => "scene")
      expect(b["inputs"].find { |i| i["key"] == "script_boa_noite" }.dig("filter", "capability")).to eq([ "script" ])

      blueprint = site.blueprints.create!(b.merge("unsupported" => [])) # anotar é com o controller
      expect(blueprint).to be_persisted
    end

    it "anota o que continua de fora" do
      bp = Blueprints::HaImport.import(<<~YAML).sole
        alias: Resto
        triggers: [ { trigger: template, value_template: "{{ true }}" }, { trigger: state, entity_id: switch.a } ]
        conditions: [ { condition: time, after: input_datetime.x }, { condition: zone, entity_id: person.a, zone: zone.home } ]
        actions:
          - { type: blink, device_id: 5078843b2aa5c9bb02ed526af3fe2937, entity_id: 7e780edc4a7889218453ed03a30494ba, domain: light }
          - delay: "{{ 5 }}"
          - action: calendar.get_events
            target: { entity_id: calendar.c }
            data: { start_date_time: "{{ now() }}" }
          - action: input_select.select_option
            target: { entity_id: input_select.m }
            data: { option: "{{ x }}" }
          - action: script.y
            data: { a: "{{ x }}" }
          - variables: { l: [ 1 ], t: "{{ state_attr('a.b', 'c') }}" }
          - event: "Nome Ruim"
          - event: ok_evento
            event_data: { a: "{{ state_attr('a.b', 'c') }}" }
          - wait_for_trigger: [ { trigger: state, entity_id: switch.a } ]
          - action: ai_task.generate_data
            data: { instructions: "x", structure: { a: { selector: { text: {} } } } }
          - action: notify.x
            data: { message: "{{ state_attr('a.b', 'c') }}" }
      YAML
      expect(bp["unsupported"]).to include("gatilho template", "horário input_datetime.x na condição", "condição zone", "ação de aparelho blink",
                                           "espera com template do HA", a_string_including("calendar.get_events com início/fim"),
                                           "valor com template do HA em select (confira)", "campos do script com template do HA (confira)",
                                           "variável l com lista ou objeto", "variáveis com template do HA (confira o texto)", "evento Nome Ruim",
                                           "dado do evento com template do HA", "ação wait_for_trigger", a_string_including("ai_task: estrutura"),
                                           a_string_including("texto com template do HA no aviso"))
      expect(bp["definition"]["triggers"]).to eq([ { "type" => "state", "point" => { "!input" => "switch_a" } } ])
    end

    it "a automação criada do blueprint troca [[entrada]] pela chave do ponto e escolhe a cena" do
      bp = site.blueprints.create!(Blueprints::HaImport.import(<<~YAML).sole)
        alias: Liga se frio
        triggers: [ { trigger: state, entity_id: sensor.t } ]
        conditions: [ "{{ states('sensor.t') | float(0) < 18 }}" ]
        actions:
          - action: scene.turn_on
            target: { entity_id: scene.inverno }
          - action: notify.notify
            data: { message: "Frio: {{ states('sensor.t') }}" }
      YAML
      temp = point("Temperatura", capability: "measure", key: "sala.temperatura", value: 15)
      lamp = point("Lâmpada")
      scene = site.scenes.create!(name: "Inverno", items: [ { "point_id" => lamp.id, "command" => "on" } ])
      expect(bp.inputs.pluck("key", "type")).to eq([ %w[sensor_t point], %w[scene_inverno scene] ])
      _d, _c, errors = bp.instantiate("sensor_t" => temp.id, "scene_inverno" => "Nome que não existe")
      expect(errors).to include(a_string_including("não existe neste local"))

      a = bp.create_automation!(name: "Frio", values: { "sensor_t" => temp.id, "scene_inverno" => "Inverno" })
      expect(a).to be_published
      expect(a.definition["conditions"]).to eq([ { "type" => "expr", "expr" => "sala.temperatura < 18" } ])
      expect(a.definition["actions"][0]).to eq("type" => "scene", "scene" => scene.id)
      expect(a.definition["actions"][1]["message"]).to eq("Frio: {{ points[\"sala.temperatura\"].text }}")
      a.update!(enabled: true)
      run = a.fire!({ "type" => "manual" })
      expect(run.reload.status).to eq("done")
      expect(lamp.reload.value).to be(true)
      expect(Notification.last.body).to start_with("Frio: 15")
    end
  end

  describe "gatilhos novos" do
    it "sistema iniciou (G7): o supervisor enfileira e cada local recebe o evento" do
      lamp = point("Lâmpada")
      build({ "triggers" => [ { "type" => "event", "event" => "system_started" } ], "actions" => [ { "type" => "command", "point" => lamp.id, "command" => "on" } ] })
      expect(Automations::TriggerTypes::EventTrigger.title("event" => "system_started")).to eq("Evento Sistema iniciou")
      expect(Automations::ActionTypes::FireEventAction.rules("event" => "system_started")).to eq([ "\"system_started\" é um evento do sistema." ])
      expect { SystemStartedJob.perform_now }.to change { lamp.reload.value }.to(true)
    end

    it "horário do ponto (input_datetime): HH:MM todo dia ou a data e hora daquele dia" do
      hora = point("Acordar", capability: "datetime", value: "12:00")
      lamp = point("Lâmpada")
      a = build({ "triggers" => [ { "type" => "time", "at_point" => hora.id, "id" => "acordar" } ],
                  "actions" => [ { "type" => "notify", "channels" => [ "in_app" ], "title" => "Gatilho {{ trigger.id }}" },
                                 { "type" => "command", "point" => lamp.id, "command" => "on" } ] })
      expect(a.errors_in(a.definition)).to eq([])
      expect(Automations::TriggerTypes::TimeTrigger.title(a.definition["triggers"][0])).to eq("Horário do ponto")
      Automations::Triggers.tick(Time.current)
      expect(Notification.last.title).to eq("Gatilho acordar")
      expect(lamp.reload.value).to be(true)

      tz = ActiveSupport::TimeZone[site.timezone]
      expect(Automations::TriggerTypes::TimeTrigger.point_due?("2026-10-30T12:00", Time.current.in_time_zone(tz).change(hour: 12, min: 0))).to be true
      expect(Automations::TriggerTypes::TimeTrigger.point_due?("2026-10-31T12:00", Time.current.in_time_zone(tz).change(hour: 12, min: 0))).to be false
      expect(Automations::TriggerTypes::TimeTrigger.rules("at" => "10:00", "at_point" => hora.id)).to include(a_string_including("só um"))
    end

    it "id do gatilho e trigger.* na expressão; timestamp e | calc no texto" do
      a = point("A")
      b = point("B")
      build({ "triggers" => [ { "type" => "state", "point" => a.id, "id" => "botao" } ],
              "conditions" => [ { "type" => "expr", "expr" => "trigger.id = 'botao' and trigger.value = true and timestamp > 0" } ],
              "actions" => [ { "type" => "command", "point" => b.id, "command" => "on" },
                             { "type" => "notify", "channels" => [ "in_app" ], "title" => "{{ \"2 * 21\" | calc }}" } ] })
      a.report!(true)
      expect(b.reload.value).to be(true)
      expect(Notification.last.title).to eq("42")
      ctx = Automations::Context.new(site: site)
      expect { ctx.render("{{ \"1 +\" | calc }}") }.to raise_error(Automations::Context::Error)
    end
  end

  describe "plugins falsos (extensão sem mexer no núcleo)" do
    it "tipo de entrada de registro do blueprint por RECORD_INPUTS" do
      stub_const("Blueprint::RECORD_INPUTS", Blueprint::RECORD_INPUTS.merge("dataset" => :datasets))
      stub_const("Blueprint::INPUT_TYPES", Blueprint::INPUT_TYPES.merge("dataset" => "Conjunto de dados"))
      ds = site.datasets.create!(name: "Leituras", key: "leituras")
      bp = site.blueprints.create!(name: "Com conjunto", domain: "automation", mode: "single", source: "manual",
                                   inputs: [ { "key" => "ds", "label" => "Conjunto", "type" => "dataset" } ],
                                   definition: { "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "dataset_record", "dataset" => { "!input" => "ds" }, "values" => { "a" => "1" } } ] })
      definition, values, errors = bp.instantiate("ds" => "Leituras")
      expect(errors).to eq([])
      expect(values).to eq("ds" => ds.id)
      expect(definition["actions"][0]["dataset"]).to eq(ds.id)
    end
  end
end
