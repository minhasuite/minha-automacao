require "rails_helper"

# Entidades do HA que ficavam sem par nos painéis importados: ação do robô
# (botão → comando do ponto do robô), DP do Tuya com outro nome, falha do
# robô por papel, entidades de serviço (o servidor, clima, speedtest) e a
# automação como ponto liga/desliga.
RSpec.describe "HA: entidades sem par" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, latitude: -7.0, longitude: -37.3) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def files(devices:, entities:, states: [], automations: "")
    { "area_registry" => { "data" => { "areas" => [] } }, "label_registry" => { "data" => { "labels" => [] } },
      "device_registry" => { "data" => { "devices" => devices } }, "entity_registry" => { "data" => { "entities" => entities } },
      "config_entries" => { "data" => { "entries" => [] } }, "states" => states, "automations" => automations }
      .transform_values { |v| v.is_a?(String) ? v : v.to_json }
  end

  it "botão do robô vira comando, umidade do Tuya casa pelo código daqui, falha pelo papel e servidor pelo Sistema" do
    allow(Integrations::SystemPlugin).to receive_messages(cpu: 7, memory: 41)
    robo = create(:device, site: site, driver: "xiaomi_miot", name: "Robô", external_id: "999")
    vacuum = create(:point, site: site, device: robo, name: "Robô", key: "robo.robo", capability: "vacuum", data_type: "enum",
                            address: { "siid" => 2, "piid" => 2, "role" => "vacuum", "actions" => Miio::Vacuum::ACTIONS })
    erro = create(:point, site: site, device: robo, name: "Erro", key: "robo.erro", capability: "problem", address: { "siid" => 2, "piid" => 66, "role" => "fault" })
    sensor = create(:device, site: site, driver: "tuya_cloud", name: "Sensor", external_id: "hum1234567")
    umidade = create(:point, site: site, device: sensor, name: "Umidade", key: "sensor.umidade", capability: "measure", data_type: "decimal",
                             address: { "dps" => "2", "code" => "humidity_value" })
    cam = create(:device, site: site, driver: "tuya_cloud", name: "Câmera", external_id: "cam1234567")
    video = create(:point, site: site, device: cam, name: "Vídeo", key: "cam.video", capability: "stream", data_type: "string", address: { "dps" => "video" })

    Integrations::HomeAssistantImport.call(site, files(
      devices: [ { "id" => "d1", "identifiers" => [ %w[xiaomi_home us_999] ] }, { "id" => "d2", "identifiers" => [ %w[tuya hum1234567] ] },
                 { "id" => "d3", "identifiers" => [ %w[tuya cam1234567] ] } ],
      entities: [
        { "id" => "e1", "entity_id" => "button.robo_lavar", "unique_id" => "xiaomi_home.robo_start_mop_wash_a_2_19", "device_id" => "d1", "platform" => "xiaomi_home" },
        { "id" => "e2", "entity_id" => "sensor.robo_falha", "unique_id" => "xiaomi_home.robo_fault_p_2_3", "device_id" => "d1", "platform" => "xiaomi_home" },
        { "id" => "e3", "entity_id" => "sensor.umidade", "unique_id" => "tuya.hum1234567va_humidity", "device_id" => "d2", "platform" => "tuya" },
        { "id" => "e4", "entity_id" => "camera.sala", "unique_id" => "tuya.cam1234567", "device_id" => "d3", "platform" => "tuya" },
        { "id" => "e5", "entity_id" => "sensor.home_assistant_core_cpu_percent", "unique_id" => "core_cpu_percent", "platform" => "hassio" },
        { "id" => "e6", "entity_id" => "sensor.speedtest_baixar", "unique_id" => "x_download", "platform" => "speedtestdotnet", "disabled_by" => "user" }
      ]
    ))

    refs = ExternalRef.map_for(site, "home_assistant", "Point")
    expect(refs.values_at("button.robo_lavar", "sensor.robo_falha", "sensor.umidade", "camera.sala")).to eq([ vacuum.id, erro.id, umidade.id, video.id ])
    expect(ExternalRef.find_by(external_id: "button.robo_lavar").kind).to eq("command:wash_mop")
    cpu = Point.find(refs["sensor.home_assistant_core_cpu_percent"])
    expect(cpu).to have_attributes(name: "Processador", value: 7)
    expect(cpu.device.points.where(writable: true)).to be_empty # leitura do servidor: nada vira campo de editar
    expect(refs).not_to have_key("sensor.speedtest_baixar") # desativada no HA: não cria o speedtest
    expect(site.integrations.pluck(:driver)).to eq([ "system" ])

    # No painel, o botão do HA vira o comando do robô (e não o "alternar" padrão do card).
    config = { "views" => [ { "path" => "robo", "title" => "Robô", "cards" => [
      { "type" => "button", "entity" => "button.robo_lavar", "name" => "Lavar pano", "tap_action" => { "action" => "toggle" } }
    ] } ] }
    dash_refs = Integrations::HaDashboards.refs_for(site, {})
    w = Dashboards::HaImport.new(config, refs: dash_refs, url_path: "robo", image: ->(_) { }, theme: nil).call.definition.dig("views", 0, "sections", 0, "widgets", 0)
    expect(w).to include("type" => "button", "bind" => vacuum.id, "label" => "Lavar pano",
                         "tap_action" => { "action" => "command", "point" => vacuum.id, "command" => "wash_mop" })
  end

  it "automação vira ponto liga/desliga: o painel do HA a encontra e ligar exige publicada" do
    lamp = create(:point, site: site, device: create(:device, site: site), name: "Lâmpada", capability: "onoff", writable: true)
    auto = Automation.create!(site: site, name: "Garagem | Push ao abrir")
    point = AutomationPoints.point_for(auto)
    expect(point).to have_attributes(name: "Garagem | Push ao abrir", capability: "onoff", value: false, writable: true)
    expect(point.device.external_id).to eq("automations")
    expect(site.devices.listed).not_to include(point.device)

    failed = Points::Command.call(point, "on", nil, source: "web", user: nil)
    expect(failed.reload).to have_attributes(status: "failed", error: "Publique a automação antes de ligar.")
    expect(auto.reload.enabled).to be false
    auto.publish!({ "triggers" => [ { "type" => "manual" } ], "conditions" => [], "actions" => [ { "type" => "command", "point" => lamp.id, "command" => "on" } ] })
    Points::Command.call(point, "on", nil, source: "web", user: nil)
    expect(auto.reload.enabled).to be true
    expect(point.reload.value).to be true
    Points::Command.call(point, "toggle", nil, source: "web", user: nil)
    expect([ auto.reload.enabled, point.reload.value ]).to eq([ false, false ])

    ExternalRef.link!(site, "home_assistant", "automation.push_ao_abrir", kind: "automation", target: auto)
    expect(Integrations::HaDashboards.refs_for(site, {}).dig("entity", "automation.push_ao_abrir")).to eq(point.id)

    auto.destroy!
    expect(Point.exists?(point.id)).to be false
  end

  it "sensor template do configuration.yaml vira sensor calculado com atributos; lista fixa de entidades conta pela chave" do
    dev = create(:device, site: site, name: "Sala")
    a = create(:point, site: site, device: dev, name: "Luz A", key: "sala.a", capability: "onoff", writable: true)
    b = create(:point, site: site, device: dev, name: "Luz B", key: "sala.b", capability: "onoff", writable: true)
    area = create(:point, site: site, device: dev, name: "Área bruta", key: "robo.area_bruta", capability: "measure", data_type: "decimal")
    { "switch.a" => a, "switch.b" => b, "sensor.area" => area }.each { |e, pt| ExternalRef.link!(site, "home_assistant", e, kind: "entity", target: pt) }
    a.report!(true)
    b.report!(false)
    area.report!(2350)
    yaml = <<~YAML
      homeassistant: { name: Casa }
      themes: !include_dir_merge_named themes
      template:
        - sensor:
            - name: Resumo casa
              unique_id: resumo_casa
              state: "{{ ['switch.a', 'switch.b'] | select('is_state', 'on') | list | count }}"
              attributes:
                luzes: >-
                  {% set n = ['switch.a', 'switch.b'] | select('is_state', 'on') | list | count %}
                  {{ 'Luzes apagadas' if n == 0 else n ~ (' luz acesa' if n == 1 else ' luzes acesas') }}
            - name: Robô área
              unique_id: robo_area
              unit_of_measurement: m²
              state: >-
                {% set a = states('sensor.area') | int(-1) %}
                {{ (a / 100) | round(0) | int if a >= 0 else none }}
        - triggers: [ { trigger: event, event_type: x } ]
          sensor:
            - name: IA pergunta
              unique_id: ia_pergunta
              state: "{{ now() }}"
    YAML
    templates = Integrations::HaMigration.templates_from(StringIO.new(yaml))
    expect(templates.size).to eq(2)
    r = Integrations::HomeAssistantImport.call(site, files(
      devices: [], states: [],
      entities: [ { "id" => "t1", "entity_id" => "sensor.resumo_casa", "unique_id" => "resumo_casa", "platform" => "template" } ]
    ).merge("templates" => templates.to_json))

    refs = ExternalRef.map_for(site, "home_assistant", "Point")
    resumo = Point.find(refs["sensor.resumo_casa"])
    expect(resumo).to have_attributes(helper: "template", name: "Resumo casa")
    expect(resumo.address["expr"]).to eq("count_points('key=sala.a,sala.b state=on')")
    HelperTypes::Template.refresh!(resumo.reload)
    expect([ resumo.reload.value.to_i, resumo.attrs["luzes"] ]).to eq([ 1, "1 luz acesa" ])
    robo = Point.find(refs["sensor.robo_area"])
    HelperTypes::Template.refresh!(robo)
    expect([ robo.reload.unit, robo.value.to_i ]).to eq([ "m²", 24 ])
    expect(r.helpers_skipped).to include("sensor.ia_pergunta: template com gatilho (refaça como automação)")
    expect(Integrations::HaMigration.templates_from(StringIO.new("x: ["))).to eq([])
  end

  it "card statistic do HA (quanto subiu hoje/no mês) vira stat com change e período, pelo histórico" do
    gasto = create(:point, site: site, device: create(:device, site: site), name: "Gasto", key: "energia.gasto", capability: "measure",
                           data_type: "decimal", unit: "BRL", history: "on_change")
    travel_to(Time.current.in_time_zone(site.timezone).beginning_of_day - 2.hours) { gasto.report!(10) }
    gasto.report!(12.5)
    ExternalRef.link!(site, "home_assistant", "sensor.energia_gasto", kind: "entity", target: gasto)
    config = { "views" => [ { "path" => "e", "title" => "E", "cards" => [
      { "type" => "statistic", "entity" => "sensor.energia_gasto", "name" => "Gasto hoje", "stat_type" => "change", "period" => { "calendar" => { "period" => "day" } } }
    ] } ] }
    defn = Dashboards::HaImport.new(config, refs: Integrations::HaDashboards.refs_for(site, {}), url_path: "e", image: ->(_) { }, theme: nil).call.definition
    w = defn.dig("views", 0, "sections", 0, "widgets", 0)
    expect(w).to include("type" => "stat", "aggregate" => "change", "period" => "day")
    expect(Dashboards::Schema.errors(defn)).to be_empty
    data, = Dashboards::Widgets::StatWidget.data(Struct.new(:site).new(site), w, [ gasto ])
    expect(data["value"]).to eq(2.5)
  end

  it "energia do Tuya (add_ele): soma o acréscimo que o aparelho empurra, ignora a leitura de estado e começa do total do HA" do
    tomada = create(:device, site: site, driver: "tuya_cloud", name: "Tomada", external_id: "tom1234567")
    energia = create(:point, site: site, device: tomada, name: "Energia", key: "tomada.energia", capability: "measure", data_type: "decimal", unit: "kWh",
                             address: { "dps" => "17", "code" => "add_ele", "accumulate" => true, "push_only" => true })
    Integrations::HomeAssistantImport.call(site, files(
      devices: [ { "id" => "d1", "identifiers" => [ %w[tuya tom1234567] ] } ],
      entities: [ { "id" => "e1", "entity_id" => "sensor.tomada_energia_total", "unique_id" => "tuya.tom1234567add_ele", "device_id" => "d1", "platform" => "tuya" } ],
      states: [ { "entity_id" => "sensor.tomada_energia_total", "state" => "37.465", "attributes" => {} } ]
    ))
    expect(energia.reload.value.to_f).to eq(37.465)
    Drivers::TuyaCloud.report(tomada, { "add_ele" => 0.012 }, push: true)
    Drivers::TuyaCloud.report(tomada, { "add_ele" => 0.012 }) # leitura de estado: repete o último acréscimo, não conta
    expect(energia.reload.value.to_f.round(3)).to eq(37.477)
  end

  it "Alexa: a descoberta traz também a Fire TV e o grupo de alto-falantes (o media_player do alexa_media), e não o app do celular" do
    integration = Integration.create!(site: site, driver: "alexa", name: "Teste Alexa", status: "ok", settings: { "host" => "alexa.amazon.com.br" },
                                      credentials: { "cookies" => { "session-id" => "S1", "csrf" => "C1" } }.to_json)
    list = [ { "accountName" => "Teste Fire TV", "deviceFamily" => "FIRE_TV", "deviceType" => "AFTX", "serialNumber" => "G0TV", "online" => true },
             { "accountName" => "Teste Todo lugar", "deviceFamily" => "WHA", "deviceType" => "A3C9", "serialNumber" => "G0GRUPO", "online" => true },
             { "accountName" => "Teste celular", "deviceFamily" => "VOX", "deviceType" => "A2TF", "serialNumber" => "G0APP", "online" => true } ]
    stub_request(:get, "https://alexa.amazon.com.br/api/devices-v2/device?cached=true").to_return(body: { "devices" => list }.to_json)
    Alexa::Import.discover!(integration)
    expect(site.devices.where(driver: "alexa").pluck(:name)).to contain_exactly("Teste Fire TV", "Teste Todo lugar")
  end
end
