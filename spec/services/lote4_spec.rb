require "rails_helper"

# Lote 4 (paridade HA, P2): clima por plugin (G11) com a ação "Ler previsão
# do tempo" (G10), widgets como plugins com o Texto em Liquid (G18a) e o
# Clima, e a visibilidade por faixa, OU e tela (G18b). Nada sai para a rede.
RSpec.describe "Lote 4: clima, widgets plugáveis e visibilidade" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, name: "Local", latitude: -10.5, longitude: -40.25) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { travel_to(Time.zone.parse("2026-10-30 12:00")) { ex.run } } }

  def build(definition, enabled: false)
    a = Automation.create!(site: site, name: "Teste #{SecureRandom.hex(3)}", kind: "automation", mode: "single")
    a.publish!(definition)
    a.update!(enabled: true) if enabled
    a
  end

  def meteo_body
    { "current" => { "time" => "2026-10-30T12:00", "temperature_2m" => 27.4, "apparent_temperature" => 29.1, "relative_humidity_2m" => 61, "wind_speed_10m" => 9.5,
                     "precipitation" => 0, "weather_code" => 2, "is_day" => 1 },
      "daily" => { "time" => %w[2026-10-29 2026-10-30 2026-10-31 2026-11-01], "weather_code" => [ 0, 2, 63, 95 ],
                   "temperature_2m_max" => [ 30, 31.2, 26, 24 ], "temperature_2m_min" => [ 18, 19.6, 18, 17 ],
                   "precipitation_probability_max" => [ 0, 10, 80, 90 ], "precipitation_sum" => [ 0, 0, 12.5, 30 ] },
      "hourly" => { "time" => %w[2026-10-30T10:00 2026-10-30T12:00 2026-10-30T13:00], "temperature_2m" => [ 25, 27, 28 ],
                    "precipitation_probability" => [ 0, 5, 10 ], "weather_code" => [ 1, 2, 3 ] } }
  end

  def stub_meteo(status: 200, body: meteo_body.to_json)
    stub_request(:get, %r{\Ahttps://api\.open-meteo\.com/v1/forecast\?}).to_return(status: status, body: body)
  end

  def weather_integration(**form)
    Integrations::WeatherPlugin.setup(site, ActionController::Parameters.new(form))
    site.integrations.find_by!(driver: "weather")
  end

  describe "clima (G11)" do
    it "lê o Open-Meteo pela localização do local e grava condição, medidas e previsão" do
      stub_meteo
      outcome = Integrations::WeatherPlugin.setup(site, ActionController::Parameters.new(name: "Tempo"))
      expect(outcome.notice).to eq("Clima conectado: parcialmente nublado.")
      expect(a_request(:get, /latitude=-10.5&longitude=-40.25&.*timezone=America(%2F|\/)Sao_Paulo/)).to have_been_made

      integration = site.integrations.find_by!(driver: "weather")
      expect(integration).to have_attributes(status: "ok", poll_s: 1800, name: "Tempo")
      expect(integration.settings).to include("provider" => "open_meteo", "account" => "Open-Meteo")
      device = site.devices.find_by!(external_id: "weather:#{integration.id}")
      main = device.points.find_by!(capability: "weather")
      expect(main).to have_attributes(value: "partlycloudy", writable: false)
      expect(ApplicationController.helpers.point_value_text(main)).to eq("Parcialmente nublado")
      measures = device.points.where(capability: "measure").to_h { |p| [ p.name, [ p.value, p.unit ] ] }
      expect(measures).to eq("Temperatura" => [ 27.4, "°C" ], "Sensação térmica" => [ 29.1, "°C" ], "Umidade" => [ 61, "%" ],
                             "Vento" => [ 9.5, "km/h" ], "Chance de chuva hoje" => [ 10, "%" ])

      expect(Weather.forecast(main, "daily").pluck("date", "condition")).to eq([ %w[2026-10-30 partlycloudy], %w[2026-10-31 rainy], %w[2026-11-01 lightning-rainy] ])
      expect(Weather.forecast(main, "hourly", 2).pluck("time", "temperature")).to eq([ [ "2026-10-30T12:00", 27 ], [ "2026-10-30T13:00", 28 ] ])

      # Segunda leitura reaproveita os pontos; noite vira "céu limpo".
      stub_meteo(body: meteo_body.deep_merge("current" => { "weather_code" => 0, "is_day" => 0 }).to_json)
      expect { Integrations.sync!(integration) }.not_to(change { device.points.count })
      expect(main.reload.value).to eq("clear-night")
    end

    it "sem localização não cria; localização própria na integração; erro do serviço fica na integração" do
      no_place = create(:site, name: "Sem lugar")
      outcome = Integrations::WeatherPlugin.setup(no_place, ActionController::Parameters.new({}))
      expect(outcome.to).to eq(:form)
      expect(no_place.integrations.count).to eq(0)

      stub_meteo
      integration = Integrations::WeatherPlugin.setup(no_place, ActionController::Parameters.new(latitude: "-3,1", longitude: "-60,02")).then { no_place.integrations.first }
      expect(integration.settings).to include("latitude" => -3.1, "longitude" => -60.02)
      expect(a_request(:get, /latitude=-3.1&longitude=-60.02/)).to have_been_made

      stub_meteo(status: 429, body: "{}")
      expect { Integrations.sync!(integration) }.to raise_error(Integrations::Error, "Open-Meteo respondeu 429.")
      expect(integration.reload).to have_attributes(status: "error", last_error: "Open-Meteo respondeu 429.")
      stub_meteo(body: "não é json")
      expect(Integrations::WeatherPlugin.login(integration, ActionController::Parameters.new({})).alert).to include("resposta inválida")
    end

    it "Ler previsão do tempo devolve agora, a lista e o resumo para as ações seguintes (G10)" do
      stub_meteo
      main = weather_integration.then { |i| Integrations::WeatherPlugin.device_for(i).points.find_by!(capability: "weather") }
      actions = [ { "type" => "weather_forecast", "point" => main.id, "kind" => "daily", "count" => 2, "response_variable" => "clima" },
                  { "type" => "set", "var" => "chuva", "expr" => "clima.forecast.1.precipitation_probability" },
                  { "type" => "set", "var" => "frase", "value" => "{{ clima.text }}|{% for d in clima.forecast %}{{ d.condition_text }};{% endfor %}" },
                  { "type" => "weather_forecast", "point" => main.id, "kind" => "hourly", "response_variable" => "horas" } ]
      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => actions }).fire!({ "type" => "manual" })
      expect(run.status).to eq("done")
      expect(run.state["vars"]).to include("chuva" => 80, "frase" => "Agora: Parcialmente nublado, 27°. Hoje: Parcialmente nublado, 20° a 31°, 10% de chance de chuva|Parcialmente nublado;Chuva;")
      expect(run.state["vars"]["horas"]).to include("count" => 2)

      lamp = create(:point, site: site, device: create(:device, site: site), name: "Luz")
      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "weather_forecast", "point" => lamp.id, "kind" => "daily" } ] }).fire!({ "type" => "manual" })
      expect(run.error).to eq("Luz não é um ponto de clima.")
    end
  end

  describe "widgets plugáveis (G18a e Clima)" do
    let(:dashboard) { Dashboard.create!(site: site, name: "Painel", kind: "home", definition: { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [] } ] }) }
    let!(:lamp) { create(:point, site: site, device: create(:device, site: site, name: "Sala"), name: "Luz", key: "sala.luz", value: true) }
    let!(:temp) { create(:point, site: site, device: lamp.device, name: "Temp", key: "sala.temp", capability: "measure", unit: "°C", value: 24.5) }

    def defn(widgets) = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => widgets } ] } ] }
    def resolve(widgets, role: "owner") = Dashboards::Resolver.new(dashboard, role: role, definition: defn(widgets)).call
    def widgets_of(r) = r["views"][0]["sections"][0]["widgets"]

    it "Texto com Liquid: valores dos pontos, laço e erro; os pontos citados viram dependência" do
      text = %(# Casa\nLuz: **{{ points["sala.luz"].text }}**{% if points["sala.temp"].value > 20 %}, quente{% endif %}\n\n- {{ site.name }})
      w = widgets_of(resolve([ { "id" => "m", "type" => "markdown", "text" => text } ])).first
      expect(w["data"]["text"]).to eq("# Casa\nLuz: **Ligado**, quente\n\n- Local")
      expect(w["deps"]).to contain_exactly(lamp.id, temp.id)
      html = ApplicationController.helpers.dw_markdown(w["data"]["text"] + "\n\n<script>x</script> *ok*")
      expect(html).to include("<p class=\"text-base font-bold text-ink\">Casa</p>", "<strong>Ligado</strong>", "<li>Local</li>", "&lt;script&gt;", "<em>ok</em>")

      expect(Dashboards::Schema.errors(defn([ { "id" => "m", "type" => "markdown", "text" => "{% if %}" } ])).first).to include("texto com Liquid inválido")
      broken = widgets_of(resolve([ { "id" => "m", "type" => "markdown", "text" => "{{ 1 | nada }}" } ])).first
      expect(broken["data"]["error"]).to include("nada")
      plain = widgets_of(resolve([ { "id" => "m", "type" => "markdown", "text" => "Só texto" } ])).first
      expect(plain["data"]).to eq("text" => "Só texto")
    end

    it "Clima: agora e previsão do ponto; tipo errado mostra a falta; forecast validado" do
      stub_meteo
      main = weather_integration.then { |i| Integrations::WeatherPlugin.device_for(i).points.find_by!(capability: "weather") }
      w = widgets_of(resolve([ { "id" => "c", "type" => "weather", "bind" => main.key, "forecast" => "hourly" } ])).first
      expect(w["data"]).to include("kind" => "hourly", "icon" => "cloud", "point_ids" => [ main.id ])
      expect(w["data"]["current"]).to include("condition_text" => "Parcialmente nublado", "temperature" => 27.4)
      expect(w["data"]["forecast"].size).to eq(2)
      expect(widgets_of(resolve([ { "id" => "c", "type" => "weather", "bind" => lamp.key } ])).first["data"]).to include("missing" => true)
      expect(Dashboards::Schema.errors(defn([ { "id" => "c", "type" => "weather", "bind" => "x", "forecast" => "anual" } ]))).to eq([ "widget c (seção s): forecast inválido" ])
      expect(Dashboards::Schema.errors(defn([ { "id" => "c", "type" => "weather" } ]))).to eq([ "widget c (seção s): bind obrigatório" ])
    end

    it "visibilidade: faixa numérica, OU, tela e dependências do tempo real (G18b)" do
      hot = { "numeric" => { "point" => "sala.temp", "above" => 20, "below" => 30 } }
      either = { "any" => [ { "state" => { "point" => "sala.luz", "is" => [ false ] } }, { "numeric" => { "point" => "sala.temp", "below" => 10 } } ] }
      list = widgets_of(resolve([ { "id" => "a", "type" => "markdown", "text" => "a", "visible_if" => hot },
                                  { "id" => "b", "type" => "markdown", "text" => "b", "visible_if" => either },
                                  { "id" => "c", "type" => "markdown", "text" => "c", "visible_if" => { "screen" => %w[mobile] } } ]))
      expect(list.map { |x| [ x["id"], x["visible"] ] }).to eq([ [ "a", true ], [ "b", false ], [ "c", true ] ])
      expect(list[0]["deps"]).to eq([ temp.id ])
      expect(list[1]["deps"]).to contain_exactly(lamp.id, temp.id)
      expect(ApplicationController.helpers.dw_screen_class(list[2])).to eq("dw-hide-tablet dw-hide-desktop")
      temp.update!(value: 5)
      expect(widgets_of(resolve([ { "id" => "b", "type" => "markdown", "text" => "b", "visible_if" => either } ])).first["visible"]).to be(true)

      bad = ->(v) { Dashboards::Schema.errors(defn([ { "id" => "x", "type" => "markdown", "text" => "x", "visible_if" => v } ])) }
      expect(bad.({ "numeric" => { "point" => "sala.temp" } }).first).to include("visible_if.numeric")
      expect(bad.({ "numeric" => { "point" => "sala.temp", "above" => "20" } }).first).to include("visible_if.numeric")
      expect(bad.({ "screen" => %w[relogio] }).first).to include("visible_if.screen")
      expect(bad.({ "any" => [] }).first).to include("visible_if.any")
      expect(bad.({ "any" => [ { "screen" => %w[mobile] } ] }).first).to include("não aceita role nem screen")
      expect(bad.({ "any" => [ { "any" => [ hot ] } ] }).first).to include("sem any dentro")
      expect(bad.(hot.merge(either))).to eq([])
    end
  end

  describe "consultas sobre o conjunto de pontos (G8)" do
    let!(:area) { create(:area, site: site, name: "Sala de estar") }
    let!(:tuya) { create(:device, site: site, area: area, name: "Tomada", driver: "tuya_local") }
    let!(:luz) { create(:point, site: site, device: tuya, name: "Luz teto", key: "sala.luz", value: true, changed_at: 2.hours.ago) }
    let!(:abajur) { create(:point, site: site, device: tuya, name: "Abajur teste", key: "sala.abajur", value: true, changed_at: 5.minutes.ago) }
    let!(:off) { create(:point, site: site, device: tuya, name: "Luz varanda", key: "varanda.luz", value: false, quality: "unavailable") }
    let!(:bat) { create(:point, site: site, device: create(:device, site: site, name: "Sensor"), name: "Bateria", key: "sensor.bat", capability: "measure", unit: "%", value: 18) }
    let!(:bat2) { create(:point, site: site, device: bat.device, name: "Bateria 2", key: "sensor.bat2", capability: "measure", unit: "%", value: 64) }

    before { Tagging.create!(tag: Tag.create!(name: "bateria"), taggable: bat) && Tagging.create!(tag: Tag.find_by!(name: "bateria"), taggable: bat2) }

    def q(text) = Points::Query.new(site).call(text).map(&:key)

    it "filtra por tipo, estado, área pelo nome, integração, tempo sem mudar, exclusão, faixa, etiqueta, ordem e corte" do
      expect(q("capability=onoff state=on")).to contain_exactly("sala.luz", "sala.abajur")
      expect(q(%(area="sala de estar" quality=unavailable))).to eq([ "varanda.luz" ])
      expect(q("integration=tuya_local unchanged_min=60")).to contain_exactly("sala.luz", "varanda.luz")
      expect(q("capability=onoff exclude=teste,varanda")).to eq([ "sala.luz" ])
      expect(q("tag=bateria below=30")).to eq([ "sensor.bat" ])
      expect(q("capability=measure sort=-value limit=1")).to eq([ "sensor.bat2" ])
      expect(q("changed_min=10")).to eq([ "sala.abajur" ])
      expect(q("name=bateria,abajur sort=name")).to eq(%w[sala.abajur sensor.bat sensor.bat2])
      expect(q("is=false device=tomada")).to eq([ "varanda.luz" ])
      expect(Points::Query.error("cor=azul")).to include("filtro desconhecido: cor")
      expect(Points::Query.error(%(area="sem fim))).to include("consulta inválida")
      expect(Points::Query.error("capability=onoff")).to be_nil
    end

    it "Liquid e expressões contam e listam, e a simulação usa os valores hipotéticos" do
      actions = [ { "type" => "set", "var" => "n", "expr" => %(count_points("capability=onoff state=on") + max_points("tag=bateria")) },
                  { "type" => "set", "var" => "media", "expr" => %(round(avg_points("tag=bateria"))) },
                  { "type" => "set", "var" => "lista", "value" => %({{ "capability=onoff state=on sort=name" | points_where | map: "name" | join: ", " }}) },
                  { "type" => "set", "var" => "fora", "value" => %({% assign f = "quality=unavailable" | points_where %}{{ f.size }} {{ f.first.text }}) } ]
      a = build({ "triggers" => [ { "type" => "manual" } ], "actions" => actions })
      run = a.fire!({ "type" => "manual" })
      expect(run.state["vars"]).to include("n" => 66, "media" => 41, "lista" => "Abajur teste, Luz teto", "fora" => "1 Desligado")

      sim = a.simulate!(points: { "sala.abajur" => "false" })
      expect(sim.state["vars"]).to include("n" => 65, "lista" => "Luz teto")

      bad = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "set", "var" => "x", "expr" => %(count_points("cor=azul")) } ] }).fire!({ "type" => "manual" })
      expect(bad.error).to include("filtro desconhecido")
      expect { Automations::Expr.calculator.evaluate!(%(count_points("state=on"))) }.to raise_error(/só funciona numa execução/)
    end

    it "lista automática do painel com os filtros novos e sensor calculado que acompanha o local" do
      dashboard = Dashboard.create!(site: site, name: "P", kind: "home", definition: { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [] } ] })
      defn = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => [
        { "id" => "l", "type" => "query_list", "query" => { "capability" => "onoff", "unchanged_min" => "60", "sort" => "name" } },
        { "id" => "c", "type" => "stat", "query" => { "tag" => "bateria", "below" => 30 } }
      ] } ] } ] }
      expect(Dashboards::Schema.errors(defn)).to eq([])
      ws = Dashboards::Resolver.new(dashboard, role: "owner", definition: defn).call["views"][0]["sections"][0]["widgets"]
      expect(ws[0]["data"]["point_ids"]).to eq([ luz.id, off.id ])
      expect(ws[1]["data"]["value"]).to eq(1)
      expect(Dashboards::Schema.errors(defn.deep_merge("views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => [ { "id" => "x", "type" => "query_list", "query" => { "cor" => "x" } } ] } ] } ])))
        .to eq([ "widget x (seção s): query com chave desconhecida" ])

      helper = HelperTypes.build(site, HelperTypes.plugin("template"))
      expect(HelperTypes.save(helper, { "name" => "Luzes acesas", "kind" => "number", "expr" => %(count_points("capability=onoff state=on")) })).to be(true)
      expect(helper.reload.value).to eq(2)
      expect(helper.address["sources"]).to include("*")
      off.report!(true)
      expect(helper.reload.value).to eq(3)
    end
  end

  describe "eventos (G6)" do
    let(:manual) { [ { "type" => "manual" } ] }

    it "Disparar evento acorda o gatilho Evento com filtro e dados; Esperar evento retoma com os dados" do
      ouvinte = build({ "triggers" => [ { "type" => "event", "event" => "porta.aberta", "match" => { "lado" => "frente" } } ],
                        "actions" => [ { "type" => "set", "var" => "quem", "value" => "{{ trigger.event }}:{{ trigger.data.quem }}" } ] }, enabled: true)
      espera = build({ "triggers" => manual, "actions" => [ { "type" => "wait_event", "event" => "porta.aberta", "match" => { "lado" => "fundos" }, "timeout" => "5m", "response_variable" => "ev" },
                                                            { "type" => "set", "var" => "vi", "value" => "{{ ev.quem }}" } ] })
      waiting = espera.fire!({ "type" => "manual" })
      expect(waiting.status).to eq("waiting")

      disparo = ->(lado) { build({ "triggers" => manual, "actions" => [ { "type" => "fire_event", "event" => "porta.aberta", "data" => { "lado" => lado, "quem" => "{{ site.name }}", "error" => "x" } } ] }) }
      run = disparo.("frente").fire!({ "type" => "manual" })
      expect(run.steps.last).to include("title" => "Disparar evento porta.aberta", "detail" => "lado, quem, error")
      got = ouvinte.runs.order(:created_at).last
      expect(got).to have_attributes(status: "done", depth: 1)
      expect(got.state["vars"]["quem"]).to eq("porta.aberta:Local")
      expect(waiting.reload.status).to eq("waiting") # filtro "fundos" não bateu

      disparo.("fundos").fire!({ "type" => "manual" })
      expect(waiting.reload.status).to eq("done")
      expect(waiting.state["vars"]).to include("vi" => "Local")
      expect(ouvinte.runs.count).to eq(1)

      sim = disparo.("frente").simulate!
      expect(sim.steps.last["result"]).to eq("simulated")
      expect(ouvinte.runs.count).to eq(1)
    end

    it "automação terminou é evento do sistema; o próprio fim não redispara; nomes do sistema são reservados" do
      alvo = build({ "triggers" => manual, "actions" => [ { "type" => "stop", "reason" => "fim" } ] })
      fiscal = build({ "triggers" => [ { "type" => "event", "event" => "automation_finished", "match" => { "automation" => alvo.name } } ],
                       "actions" => [ { "type" => "set", "var" => "st", "value" => "{{ trigger.data.status }}/{{ trigger.data.reason }}" } ] }, enabled: true)
      todos = build({ "triggers" => [ { "type" => "event", "event" => "automation_finished" } ], "actions" => [ { "type" => "set", "var" => "x", "expr" => "1" } ] }, enabled: true)
      alvo.fire!({ "type" => "manual" })
      expect(fiscal.runs.sole.state["vars"]["st"]).to eq("stopped/fim")
      expect(todos.runs.count).to eq(2) # o fim do alvo e o do fiscal; o próprio fim não conta
      expect(AutomationRun.where(status: "loop").count).to eq(0)

      errors = Automations::Dsl.errors({ "triggers" => manual, "actions" => [ { "type" => "fire_event", "event" => "automation_finished" },
                                                                                { "type" => "fire_event", "event" => "Com Espaço" } ] }, site).join(" | ")
      expect(errors).to include("\"automation_finished\" é um evento do sistema", "nome do evento")
      expect(Automations::TriggerTypes["event"].title({ "event" => "automation_finished" })).to eq("Evento Automação ou script terminou")
    end
  end

  describe "importar automações e scripts do HA (G32)" do
    let(:automations_yaml) do
      <<~YAML
        - id: "1"
          alias: Varanda | Luz | Ligar às 18h
          trigger:
            - platform: time
              at: "18:00:00"
          condition:
            - condition: template
              value_template: "{{ is_state('sun.sun', 'below_horizon') }}"
          action:
            - service: switch.turn_on
              target:
                entity_id: [switch.varanda, light.jardim]
            - delay: "00:05:00"
        - alias: Porta | Aviso
          triggers:
            - trigger: state
              entity_id: binary_sensor.porta
              to: "on"
              for: { minutes: 2 }
          actions:
            - action: notify.notify
              data: { title: Porta, message: "Aberta" }
        - alias: Só serviço estranho
          trigger: [ { platform: homeassistant, event: start }, { platform: time_pattern, minutes: "/30" }, { platform: event, event_type: mobile_app_notification_action, event_data: { action: OK } }, { platform: webhook, webhook_id: x } ]
          action: [ { service: shell_command.algo } ]
        - nao_e_automacao: true
      YAML
    end

    it "uma automação por blueprint, entidade fixa vira entrada de ponto, relatório do que não converteu" do
      list = Blueprints::HaImport.import(automations_yaml)
      expect(list.map { |a| a["name"] }).to eq([ "Varanda | Luz | Ligar às 18h", "Porta | Aviso", "Só serviço estranho" ])
      luz = list[0]
      expect(luz["inputs"].map { |i| [ i["key"], i["label"], i.dig("filter", "capability") ] }).to eq([ [ "switch_varanda", "switch.varanda", %w[onoff] ], [ "light_jardim", "light.jardim", %w[onoff] ] ])
      expect(luz["definition"]["triggers"]).to eq([ { "type" => "time", "at" => "18:00" } ])
      expect(luz["definition"]["actions"]).to eq([ { "type" => "command", "point" => { "!input" => "switch_varanda" }, "command" => "on" },
                                                   { "type" => "command", "point" => { "!input" => "light_jardim" }, "command" => "on" },
                                                   { "type" => "wait", "for" => "5m" } ])
      expect(luz["unsupported"]).to eq([ "condição template" ])
      expect(list[1]["definition"]["triggers"]).to eq([ { "type" => "state", "point" => { "!input" => "binary_sensor_porta" }, "to" => true, "for" => "2m" } ])
      expect(list[1]["inputs"].first.dig("filter", "capability")).to eq(%w[contact motion problem tamper])
      expect(list[2]["unsupported"]).to include("ação shell_command.algo")
      expect(list[2]["definition"]["triggers"]).to eq([ { "type" => "event", "event" => "system_started" }, { "type" => "time", "every" => "30m" }, { "type" => "event", "event" => "mobile_app_notification_action", "match" => { "action" => "OK" } },
                                                        { "type" => "webhook" } ])

      scripts = Blueprints::HaImport.import("boa_noite:\n  alias: Boa noite\n  sequence:\n    - service: light.turn_off\n      entity_id: light.sala\n")
      expect(scripts.sole).to include("name" => "Boa noite", "domain" => "script")
      expect(scripts.sole["definition"]["actions"]).to eq([ { "type" => "command", "point" => { "!input" => "light_sala" }, "command" => "off" } ])

      bp = site.blueprints.create!(list[0])
      lamp = create(:point, site: site, device: create(:device, site: site), name: "Varanda")
      expect(bp.inputs.size).to eq(2)
      expect(lamp).to be_persisted
      expect { Blueprints::HaImport.import("- a: 1") }.to raise_error(Blueprints::HaImport::Error, /Não achei blueprint/)
      expect(Blueprints::HaImport.import("blueprint:\n  name: X\n  domain: automation\ntrigger: []\naction: []\n").sole["name"]).to eq("X")
    end

    it "controle de fluxo do HA vira se, escolher, parar se falso, parar, repetir e variáveis" do
      yaml = <<~YAML
        alias: Fluxo
        trigger: [ { platform: state, entity_id: switch.a } ]
        action:
          - variables: { msg: "{{ states('switch.a') }}", n: 2 }
          - if: [ { condition: state, entity_id: switch.a, state: "on" } ]
            then: [ { service: switch.turn_on, entity_id: switch.b } ]
            else: [ { service: switch.turn_off, entity_id: switch.b } ]
          - choose:
              - conditions: [ { condition: template, value_template: "{{ true }}" } ]
                sequence: [ { stop: "fim" } ]
            default: [ { delay: 5 } ]
          - condition: numeric_state
            entity_id: sensor.t
            above: 20
          - repeat: { count: 3, sequence: [ { delay: 1 } ] }
          - repeat: { until: [ { condition: state, entity_id: switch.b, state: "off" } ], sequence: [ { delay: 1 } ] }
          - repeat: { for_each: [1, 2], sequence: [] }
          - stop: erro
            error: true
      YAML
      bp = Blueprints::HaImport.import(yaml).sole
      acts = bp["definition"]["actions"]
      expect(acts.map { |a| a["type"] }).to eq(%w[set set if choose condition repeat repeat stop])
      expect(acts[0]).to eq("type" => "set", "var" => "msg", "expr" => "[[switch_a]]")
      expect(acts[1]).to eq("type" => "set", "var" => "n", "expr" => "2")
      expect(acts[2]).to include("conditions" => [ { "type" => "state", "point" => { "!input" => "switch_a" }, "is" => true } ],
                                 "else" => [ { "type" => "command", "point" => { "!input" => "switch_b" }, "command" => "off" } ])
      expect(acts[3]).to eq("type" => "choose", "options" => [ { "conditions" => [ { "type" => "expr", "expr" => "true" } ], "actions" => [ { "type" => "stop", "reason" => "fim" } ] } ],
                            "default" => [ { "type" => "wait", "for" => "5s" } ])
      expect(acts[4]["conditions"]).to eq([ { "type" => "numeric", "point" => { "!input" => "sensor_t" }, "above" => 20 } ])
      expect(acts[5]).to include("count" => 3)
      expect(acts[6]["until"].size).to eq(1)
      expect(acts[7]).to eq("type" => "stop", "reason" => "erro", "error" => true)
      expect(bp["unsupported"]).to eq([ "repetição for_each (for_each)" ])
    end
  end

  describe "pontos de sistema (G19)" do
    it "disco, backup, integrações com erro, automações e pontos sem sinal viram pontos e acompanham a mudança" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "minha_automacao-2026-10-29.sql.gz"), "x")
        stamp = ->(name, at) { File.utime(Time.zone.parse(at).to_time, Time.zone.parse(at).to_time, File.join(dir, name)) }
        stamp.call("minha_automacao-2026-10-29.sql.gz", "2026-10-29 03:00")
        File.write(File.join(dir, "parcial.sql.gz.tmp"), "x")
        stub_const("ENV", ENV.to_h.merge("BACKUP_DIR" => dir))
        site.integrations.create!(driver: "calendar", name: "Agenda", status: "error")
        create(:point, site: site, device: create(:device, site: site), name: "Sem sinal", quality: "unavailable")
        failed = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "stop", "reason" => "x", "error" => true } ] }, enabled: true)
        failed.fire!({ "type" => "manual" })

        outcome = Integrations::SystemPlugin.setup(site, {})
        expect(outcome.notice).to start_with("Sistema adicionado")
        integration = site.integrations.find_by!(driver: "system")
        values = Integrations::SystemPlugin.device_for(integration).points.to_h { |p| [ p.address["field"], p.value ] }
        expect(values).to include("integrations_error" => 1, "integrations_error_names" => "Agenda", "automations_on" => 1, "runs_24h" => 1,
                                  "failed_24h" => 1, "running" => 0, "points_unavailable" => 1, "backup_late" => true)
        expect(values["backup_at"]).to start_with("2026-10-29T03:00")
        expect(values["disk_used"]).to be_between(0, 100)
        expect(values["disk_free"]).to be >= 0

        File.write(File.join(dir, "minha_automacao-2026-10-30.sql.gz"), "x")
        stamp.call("minha_automacao-2026-10-30.sql.gz", "2026-10-30 03:00")
        Integrations::SystemPlugin.setup(site, {})
        expect(site.integrations.where(driver: "system").count).to eq(1)
        late = Integrations::SystemPlugin.device_for(integration).points.find_by!("address->>'field' = 'backup_late'")
        expect(late.value).to be(false)
      end
      expect(Integrations::SystemPlugin.last_backup("/nao/existe")).to be_nil
      allow(Open3).to receive(:capture2).and_raise(Errno::ENOENT)
      expect(Integrations::SystemPlugin.disk).to be_nil
    end
  end

  describe "plugins falsos (aberto/fechado)" do
    it "um provedor de clima novo entra pelo registro e alimenta pontos, ação e widget sem mexer no núcleo" do
      fake = Class.new(Weather::Providers::Base) do
        describe key: "falso", label: "Clima de teste (com chave)", needs_key: true
        def self.fetch(lat:, lon:, zone:, api_key: nil)
          raise Weather::Error, "chave errada" unless api_key == "k1"

          { "current" => { "condition" => "windy", "temperature" => lat.abs + lon.abs, "pressure" => 1000 },
            "daily" => [ { "date" => "2026-10-30", "condition" => "windy", "temperature_max" => 22, "temperature_min" => 15 } ], "hourly" => [] }
        end
      end
      stub_const("Weather::Providers::Falso", fake)
      stub_const("Weather::PROVIDERS", Weather::PROVIDERS + %w[Falso])

      expect(Weather.choices).to include("falso" => "Clima de teste (com chave)")
      outcome = Integrations::WeatherPlugin.setup(site, ActionController::Parameters.new(provider: "falso"))
      expect(outcome.alert).to include("precisa de uma chave")
      integration = site.integrations.find_by!(driver: "weather")
      Integrations::WeatherPlugin.login(integration, ActionController::Parameters.new(api_key: "k1"))
      expect(integration.reload.status).to eq("ok")
      expect(integration.secrets).to eq("api_key" => "k1")
      device = Integrations::WeatherPlugin.device_for(integration)
      expect(device.points.pluck(:name, :value)).to contain_exactly([ "Clima", "windy" ], [ "Temperatura", 50.75 ]) # medida que o provedor não dá não nasce
      main = device.points.find_by!(capability: "weather")
      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "weather_forecast", "point" => main.id, "kind" => "daily", "response_variable" => "c" } ] })
              .fire!({ "type" => "manual" })
      expect(run.state["vars"]["c"]["text"]).to eq("Agora: Ventania, 51°. Hoje: Ventania, 15° a 22°")
    end

    it "um filtro de consulta novo entra pelo registro e vale no painel, no Liquid e nas expressões" do
      lamp = create(:point, site: site, device: create(:device, site: site), name: "Lâmpada", key: "l1", value: true, icon: "light-bulb")
      create(:point, site: site, device: lamp.device, name: "Outra", key: "l2", value: true)
      stub_const("Points::Query::FILTERS", Points::Query::FILTERS.merge("icon" => ->(_q, p, v) { p.icon == v }))
      stub_const("Points::Query::KEYS", Points::Query::FILTERS.keys + Points::Query::OPTIONS)
      expect(Points::Query.new(site).call("icon=light-bulb").map(&:key)).to eq([ "l1" ])
      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "set", "var" => "n", "expr" => %(count_points("icon=light-bulb")) } ] }).fire!({ "type" => "manual" })
      expect(run.state["vars"]["n"]).to eq(1)
    end

    it "um gatilho de evento novo escuta um evento próprio sem mexer no disparo" do
      fake = Class.new(Automations::TriggerTypes::Base) do
        describe key: "falso_evento", label: "Evento de teste"
        def self.event = "teste.algo"
        def self.fires_on_event?(_t, payload) = payload["n"].to_i > 1
      end
      stub_const("Automations::TriggerTypes::FalsoEvento", fake)
      stub_const("Automations::TriggerTypes::PLUGINS", Automations::TriggerTypes::PLUGINS + %w[FalsoEvento])
      a = build({ "triggers" => [ { "type" => "falso_evento" } ], "actions" => [ { "type" => "set", "var" => "x", "expr" => "1" } ] }, enabled: true)
      Automations::Triggers.event(site.id, "teste.algo", { "n" => 1 })
      Automations::Triggers.event(site.id, "teste.algo", { "n" => 2 })
      expect(a.runs.count).to eq(1)
      expect(Automations::Triggers.reserved_event?("teste.algo")).to be(true)
    end

    it "um tipo de card novo entra pelo registro: valida, resolve, edita e desenha sem mexer no núcleo" do
      fake = Class.new(Dashboards::Widgets::Base) do
        describe type: "contagem_falsa", label: "Contagem de teste", icon: "calculator", required: %w[bind], params: %w[prefixo], bind: true
        def self.errors(w) = w["prefixo"].to_s.size > 10 ? [ "prefixo longo" ] : []
        def self.data(r, w, binds) = [ { "text" => "#{w['prefixo']}#{binds.first&.value}" }, [ r.point("extra") ].compact ]
        def self.partial = "web/dashboards/widgets/markdown"
      end
      stub_const("Dashboards::Widgets::ContagemFalsa", fake)
      stub_const("Dashboards::Widgets::PLUGINS", Dashboards::Widgets::PLUGINS + %w[ContagemFalsa])
      dashboard = Dashboard.create!(site: site, name: "Painel", kind: "home", definition: { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [] } ] })
      lamp = create(:point, site: site, device: create(:device, site: site), name: "N", key: "n", capability: "measure", value: 3)
      extra = create(:point, site: site, device: lamp.device, name: "E", key: "extra")
      definition = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => [
        { "id" => "f", "type" => "contagem_falsa", "bind" => "n", "prefixo" => "Total: " }
      ] } ] } ] }

      expect(Dashboards::Schema.labels).to include("contagem_falsa" => "Contagem de teste")
      expect(Dashboards::Schema.errors(definition)).to eq([])
      expect(Dashboards::Schema.errors(definition.deep_dup.tap { |d| d["views"][0]["sections"][0]["widgets"][0]["prefixo"] = "x" * 11 })).to eq([ "widget f (seção s): prefixo longo" ])
      w = Dashboards::Resolver.new(dashboard, role: "owner", definition: definition).call["views"][0]["sections"][0]["widgets"][0]
      expect(w["data"]).to eq("text" => "Total: 3")
      expect(w["deps"]).to contain_exactly(lamp.id, extra.id)
      expect(fake.attrs(ActionController::Parameters.new(bind: lamp.id, prefixo: "Q"))).to eq("bind" => lamp.id, "prefixo" => "Q")
      html = ApplicationController.render(partial: "web/dashboards/widget", locals: { w: w, points: {}, dashboard: dashboard, live: false })
      expect(html).to include("Total: 3")
    end
  end
end
