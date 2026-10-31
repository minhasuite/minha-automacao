require "rails_helper"

# Pacote 3: pessoas, zonas e presença; painel de alarme. Tudo por registro
# (rastreadores, modos, sondas da rede, gatilhos, condições e widgets).
RSpec.describe "Pacote 3: presença e alarme" do
  include ActiveJob::TestHelper

  let(:tenant) { create(:tenant) }
  let(:user) { create(:user, tenant: tenant, name: "Ana Souza") }
  let(:site) { create(:site, latitude: -15.80, longitude: -47.90) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def helper(type, form = {})
    point = HelperTypes.build(site, HelperTypes.plugin(type))
    raise "não salvou: #{point.errors.full_messages}" unless HelperTypes.save(point, { "name" => "#{type} 1" }.merge(form))

    point.reload
  end

  def cmd(point, command, value = nil) = Points::Command.call(point, command, value, source: "web", user: nil).tap { point.reload }

  def automation(definition)
    a = Automation.create!(site: site, name: "Teste #{SecureRandom.hex(3)}", kind: "automation", mode: "queued")
    a.publish!(definition)
    a.update!(enabled: true)
    a
  end

  describe "pessoas e zonas" do
    let(:phone) { Integrations::MobileAppPlugin.register!(site, user, install_id: "abcdefgh12", name: "Celular da Ana") }
    let(:gps) { phone.points.find_by!(address: { "field" => "location" }) }

    before do
      Integrations::MobileAppPlugin.report!(phone, "location" => { "latitude" => -15.80, "longitude" => -47.90, "accuracy" => 10 },
                                                   "wifi" => "Outra", "battery" => 80)
    end

    it "a pessoa segue o GPS do celular entre a casa, outra zona e fora; a zona conta quem está nela" do
      work = helper("zone", "name" => "Trabalho", "latitude" => "-15,70", "longitude" => "-47,80", "radius_m" => "300")
      ana = helper("person", "name" => "Ana", "user_id" => user.id, "sources" => [ gps.id ])
      home = HelperTypes::Zone.home(site)
      expect(home).to have_attributes(name: "Casa", value: 1)
      expect(ana).to have_attributes(value: "Casa", quality: "good")
      expect(ana.attrs).to eq("source" => "Presença")
      expect(ana.options).to eq(%w[Casa Trabalho Fora])

      Integrations::MobileAppPlugin.report!(phone.reload, "location" => { "latitude" => -15.70, "longitude" => -47.80, "accuracy" => 20 })
      expect([ ana.reload.value, home.reload.value, work.reload.value ]).to eq([ "Trabalho", 0, 1 ])
      expect(gps.reload.attrs["zone"]).to eq("Trabalho")

      Integrations::MobileAppPlugin.report!(phone.reload, "location" => { "latitude" => -10.0, "longitude" => -40.0, "accuracy" => 20 })
      expect([ ana.reload.value, work.reload.value ]).to eq([ "Fora", 0 ])
    end

    it "prioridade: Wi-Fi de casa e a rede só dizem 'em casa'; vale a primeira fonte com zona" do
      wifi = phone.points.find_by!(device_class: "wifi_ssid")
      net = create(:point, site: site, device: create(:device, site: site, name: "Roteador"), name: "Conectado", capability: "onoff",
                           device_class: "presence", value: false, writable: false)
      ana = helper("person", "name" => "Ana", "sources" => [ wifi.id, net.id ], "home_ssids" => "MinhaRede, MinhaRede-5G")
      expect(ana.value).to eq("Fora") # Wi-Fi de fora não opina; a rede diz fora

      Integrations::MobileAppPlugin.report!(phone.reload, "wifi" => "\"minharede-5g\"")
      expect(ana.reload).to have_attributes(value: "Casa")
      expect(ana.attrs["source"]).to eq("Wi-Fi")

      net.report!(true, quality: "unavailable") # sem sinal não conta
      Integrations::MobileAppPlugin.report!(phone.reload, "wifi" => "Outra")
      expect(ana.reload).to have_attributes(value: "Casa", quality: "unavailable") # ninguém sabe dizer agora
    end

    it "um rastreador novo entra pelo registro sem mudar a pessoa" do
      fake = Class.new(People::Trackers::Base) do
        describe label: "Crachá"
        def self.applies?(point) = point.device_class == "badge"
        def self.zone(point, _person, zones) = point.value == true ? zones.find { |z| z.name == "Escritório" }&.name : nil
      end
      stub_const("People::Trackers::Badge", fake)
      stub_const("People::TRACKERS", People::TRACKERS + %w[Badge])
      helper("zone", "name" => "Escritório", "latitude" => "1", "longitude" => "1")
      badge = create(:point, site: site, device: create(:device, site: site), name: "Crachá", capability: "onoff", device_class: "badge", value: false)
      ana = helper("person", "name" => "Ana", "sources" => [ badge.id, gps.id ])
      expect(ana.value).to eq("Casa")
      badge.report!(true)
      expect(ana.reload.value).to eq("Escritório")
      expect(People.trackable(site)).to include(badge)
    end

    it "gatilhos: entrou/saiu de zona, o primeiro chegou e todos saíram; condição alguém em casa" do
      ana = helper("person", "name" => "Ana", "sources" => [ gps.id ])
      home = HelperTypes::Zone.home(site)
      left = automation("triggers" => [ { "type" => "zone", "point" => ana.id, "zone" => home.id, "event" => "leave" } ],
                        "actions" => [ { "type" => "trace_note", "message" => "saiu" } ])
      all_left = automation("triggers" => [ { "type" => "presence", "point" => home.id, "event" => "all_left" } ],
                            "conditions" => [ { "type" => "zone", "point" => home.id, "state" => "nobody" } ],
                            "actions" => [ { "type" => "trace_note", "message" => "vazia" } ])
      first = automation("triggers" => [ { "type" => "presence", "point" => home.id, "event" => "first_arrived" } ],
                         "actions" => [ { "type" => "trace_note", "message" => "chegou" } ])

      Integrations::MobileAppPlugin.report!(phone.reload, "location" => { "latitude" => -10.0, "longitude" => -40.0 })
      expect([ left, all_left, first ].map { |a| a.runs.count }).to eq([ 1, 1, 0 ])
      expect(all_left.runs.last.status).to eq("done")
      Integrations::MobileAppPlugin.report!(phone.reload, "location" => { "latitude" => -15.80, "longitude" => -47.90 })
      expect([ left, all_left, first ].map { |a| a.runs.count }).to eq([ 1, 1, 1 ])
    end

    it "privacidade: retenção apaga a coordenada exata e 0 h guarda só a zona" do
      integration = phone.integration
      expect(gps.attrs.keys).to include("latitude", "zone")
      travel_to(25.hours.from_now) { Integrations::MobileAppPlugin.tick(Time.current) }
      expect(gps.reload.attrs.keys).to contain_exactly("distance_m", "zone")

      integration.update!(settings: integration.settings.merge("location_keep_h" => 0))
      Integrations::MobileAppPlugin.report!(phone.reload, "location" => { "latitude" => -15.80, "longitude" => -47.90 })
      expect(gps.reload.attrs).to eq("distance_m" => 0, "zone" => "Fora")
      ana = helper("person", "name" => "Ana", "sources" => [ gps.id ]) # a zona Casa nasce agora; a próxima leitura já cai nela
      Integrations::MobileAppPlugin.report!(phone.reload, "location" => { "latitude" => -15.80, "longitude" => -47.90 })
      expect(ana.reload.value).to eq("Casa")
    end

    it "widget de pessoas e resumo da API" do
      helper("person", "name" => "Ana", "user_id" => user.id, "sources" => [ gps.id ])
      expect(People.summary(site).first).to include("name" => "Ana", "zone" => "Casa", "home" => true, "user_id" => user.id)
      dash = site.dashboards.create!(name: "P", definition: { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => [ { "id" => "w1", "type" => "people" } ] } ] } ] })
      w = Dashboards::Resolver.new(dash, role: "owner").call["views"].first["sections"].first["widgets"].first
      expect(w["data"]["people"].first).to include("name" => "Ana", "initials" => "A", "home" => true)
    end
  end

  describe "rastreador de rede" do
    it "sonda por registro, 'fora' só depois do tempo de tolerância, e serve de fonte da pessoa" do
      seen = { "192.168.0.23" => true }
      fake = Module.new do
        define_singleton_method(:label) { "Sonda de teste" }
        define_singleton_method(:up?) { |host, _s| seen[host] }
      end
      stub_const("Integrations::NetworkTrackerPlugin::Fake", fake)
      stub_const("Integrations::NetworkTrackerPlugin::PROBES", { "fake" => "Fake" })
      outcome = Integrations::NetworkTrackerPlugin.setup(site, ActionController::Parameters.new(hosts: "Celular da Ana = 192.168.0.23\nlixo !!\n", method: "fake", consider_home: "3m"))
      expect(outcome.notice).to include("1 de 1")
      point = site.points.find_by!(device_class: "presence")
      expect(point).to have_attributes(value: true, writable: false)
      ana = helper("person", "name" => "Ana", "sources" => [ point.id ])
      expect(ana.value).to eq("Casa")

      integration = site.integrations.find_by!(driver: "network_tracker")
      seen["192.168.0.23"] = false
      Integrations.sync!(integration)
      expect(point.reload.value).to be true # ainda dentro dos 3 min
      travel_to(4.minutes.from_now) { Integrations.sync!(integration) }
      expect([ point.reload.value, ana.reload.value ]).to eq([ false, "Fora" ])
    end

    it "TCP: recusa conta como presente; ping sem o comando vira erro claro" do
      allow(Socket).to receive(:tcp).and_raise(Errno::ECONNREFUSED)
      expect(Integrations::NetworkTrackerPlugin::Tcp.up?("192.168.0.9", {})).to be true
      allow(Socket).to receive(:tcp).and_raise(Errno::ETIMEDOUT)
      expect(Integrations::NetworkTrackerPlugin::Tcp.up?("192.168.0.9", {})).to be false
      allow(Open3).to receive(:capture2e).and_raise(Errno::ENOENT)
      expect { Integrations::NetworkTrackerPlugin::Ping.up?("192.168.0.9", {}) }.to raise_error(Integrations::Error, /ping/)
    end
  end

  describe "painel de alarme" do
    let(:door) { create(:point, site: site, device: create(:device, site: site, name: "Porta"), name: "Porta da frente", capability: "contact", value: false) }
    let(:pir) { create(:point, site: site, device: create(:device, site: site, name: "Sala"), name: "Movimento", capability: "motion", value: false) }
    let(:panel) do
      helper("alarm_panel", "name" => "Alarme", "code" => "1234", "trigger_time" => "2m",
                            "modes" => { "armed_away" => { "enabled" => "1", "sensors" => [ door.id, pir.id ], "exit" => "30s", "entry" => "20s" },
                                         "armed_home" => { "enabled" => "1", "sensors" => [ door.id ], "exit" => "0s", "entry" => "0s" } })
    end

    it "arma com atraso de saída, conta a entrada, dispara e volta ao modo; o código nunca é gravado" do
      expect(panel).to have_attributes(value: "disarmed", risk: "sensitive")
      expect(Points::Command.commands_for(panel)).to eq(%w[arm_home arm_away disarm trigger])
      expect(panel.address["code_digest"]).to start_with("$2")
      expect(PointSerializer.new(panel).to_h["address"]).not_to have_key("code_digest")

      cmd(panel, "arm_away")
      expect(panel.value).to eq("arming")
      expect(Command.where(point: panel).pluck(:value)).to all(be_nil)
      pir.report!(true) # durante a saída não dispara
      expect(panel.reload.value).to eq("arming")
      pir.report!(false)

      HelperTimerJob.perform_now(panel.id, "velho")
      expect(panel.reload.value).to eq("arming")
      HelperTimerJob.perform_now(panel.id, panel.address["stamp"])
      expect(panel.reload.value).to eq("armed_away")

      door.report!(true)
      expect(panel.reload).to have_attributes(value: "pending")
      expect(panel.attrs["tripped_by"]).to eq([ "Porta da frente" ])
      HelperTimerJob.perform_now(panel.id, panel.address["stamp"])
      expect(panel.reload.value).to eq("triggered")
      HelperTimerJob.perform_now(panel.id, panel.address["stamp"])
      expect(panel.reload.value).to eq("armed_away")

      expect { cmd(panel, "disarm", "9999") }.to raise_error(Points::Command::Error, /incorreto/)
      cmd(panel, "disarm", "1234")
      expect(panel.value).to eq("disarmed")
      expect(Command.where(point: panel).pluck(:value)).to all(be_nil)
    end

    it "não arma com sensor aberto; modo sem atraso arma e dispara na hora; valor direto é recusado" do
      door.report!(true)
      expect { cmd(panel, "arm_home") }.to raise_error(Points::Command::Error, /Porta da frente/)
      door.report!(false)
      cmd(panel, "arm_home")
      expect(panel.value).to eq("armed_home")
      pir.report!(true) # não é sensor do modo em casa
      expect(panel.reload.value).to eq("armed_home")
      door.report!(true)
      expect(panel.reload.value).to eq("triggered")
      expect { HelperTypes::AlarmPanel.check(panel, "disarmed") }.to raise_error(Points::Command::Error)
    end

    it "gatilho 'Alarme mudou' e condição 'Alarme está' (armado em qualquer modo); widget com os modos do registro" do
      siren = automation("triggers" => [ { "type" => "alarm", "point" => panel.id, "to" => "triggered" } ],
                         "conditions" => [ { "type" => "alarm", "point" => panel.id, "is" => "triggered" } ],
                         "actions" => [ { "type" => "trace_note", "message" => "sirene (automação do usuário)" } ])
      cmd(panel, "trigger")
      expect(siren.runs.last.status).to eq("done")
      expect(Automations::ConditionTypes::AlarmCondition.fields.find { |f| f.name == "is" }.choices).to include("armed", "armed_night")

      dash = site.dashboards.create!(name: "A", definition: { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => [ { "id" => "w1", "type" => "alarm", "bind" => panel.id } ] } ] } ] })
      w = Dashboards::Resolver.new(dash, role: "owner").call["views"].first["sections"].first["widgets"].first
      expect(w["data"]["modes"].map { |m| m["command"] }).to eq(%w[arm_home arm_away])
      expect(w["data"]["state"]).to eq("triggered")
    end

    it "um modo novo entra pelo registro (botão, comando, gatilho e condição) sem mudar o painel" do
      stub_const("HelperTypes::AlarmPanel::MODES", HelperTypes::AlarmPanel::MODES.merge("armed_custom" => { label: "Festa", command: "arm_custom" }))
      p2 = helper("alarm_panel", "name" => "Alarme 2", "code" => "4321", "modes" => { "armed_custom" => { "enabled" => "1", "sensors" => [ door.id ] } })
      expect(Points::Command.commands_for(p2)).to eq(%w[arm_custom disarm trigger])
      cmd(p2, "arm_custom")
      expect(p2.value).to eq("armed_custom")
      expect(HelperTypes::AlarmPanel.value_text(p2)).to eq("Armado (festa)")
      expect(Automations::TriggerTypes::AlarmTrigger.fields.find { |f| f.name == "to" }.choices).to include("armed_custom")
    end

    it "pede código para armar quando configurado e valida o formulário" do
      p2 = helper("alarm_panel", "name" => "Cofre", "code" => "1234", "code_arm" => "1", "modes" => { "armed_away" => { "enabled" => "1" } })
      expect { cmd(p2, "arm_away") }.to raise_error(Points::Command::Error, /incorreto/)
      cmd(p2, "arm_away", "1234")
      expect(p2.value).to eq("armed_away")
      bad = HelperTypes.build(site, HelperTypes::AlarmPanel)
      expect(HelperTypes.save(bad, "name" => "x", "code" => "12", "modes" => {})).to be false
      expect(bad.errors.full_messages.join).to include("4 a 8 números")
    end
  end
end
