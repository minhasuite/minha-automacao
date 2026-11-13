require "rails_helper"

# Pessoas (presença por pessoa: tolerância, cômodo, dia, confiança, assistente
# do celular, condição "Pessoa na zona") e Energia por aparelho (custo pela
# tarifa do local, comparação, média aprendida por hora e aviso agrupado).
# Coordenadas sempre falsas (1,0 / 1,0): nunca localização real.
RSpec.describe "Pessoas e Energia" do
  include ActiveJob::TestHelper

  let(:owner) { create(:user, name: "Dona Teste") }
  let(:tenant) { owner.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa Teste", latitude: 1.0, longitude: 1.0) } }
  let(:zone) { ActiveSupport::TimeZone["America/Sao_Paulo"] }

  def login(user) = post("/entrar", params: { email: user.email, password: "12345678" })

  def helper(type, form = {})
    within(tenant) do
      point = HelperTypes.build(site, HelperTypes.plugin(type))
      raise "não salvou: #{point.errors.full_messages}" unless HelperTypes.save(point, { "name" => "#{type} 1" }.merge(form))

      point.reload
    end
  end

  def net_point(value = true)
    within(tenant) do
      create(:point, site: site, device: create(:device, site: site, name: "Roteador Teste"), name: "Conectado", capability: "onoff",
                     device_class: "presence", value: value, writable: false)
    end
  end

  describe "presença" do
    it "tolerância: 'Fora' só depois do tempo; voltar no meio cancela; chegar vale na hora" do
      net = net_point(true)
      t0 = Time.current.change(usec: 0)
      ana = travel_to(t0) { helper("person", "name" => "Ana", "sources" => [ net.id ], "away_delay_min" => "3") }
      expect(ana).to have_attributes(value: "Casa")
      expect(ana.address["away_delay_s"]).to eq(180)

      travel_to(t0 + 1.minute) { within(tenant) { net.report!(false) } }
      expect(ana.reload.value).to eq("Casa")
      expect(ana.attrs["leaving_at"]).to be_present

      travel_to(t0 + 2.minutes) { within(tenant) { net.report!(true) } } # o Wi-Fi voltou: não piscou
      expect(ana.reload.attrs).not_to have_key("leaving_at")
      expect(ana.value).to eq("Casa")

      travel_to(t0 + 5.minutes) { within(tenant) { net.report!(false) } }
      travel_to(t0 + 6.minutes) { within(tenant) { HelperTypes::Person.tick(ana.reload, Time.current) } }
      expect(ana.reload.value).to eq("Casa")
      travel_to(t0 + 8.minutes + 1.second) { within(tenant) { HelperTypes::Person.tick(ana.reload, Time.current) } }
      expect(ana.reload).to have_attributes(value: "Fora")
      expect(ana.changed_at).to be_within(1.second).of(t0 + 5.minutes) # a saída conta de quando começou
      expect(ana.attrs).not_to have_key("leaving_at")

      travel_to(t0 + 9.minutes) { within(tenant) { net.report!(true) } }
      expect(ana.reload.value).to eq("Casa") # chegar vale na hora

      moves = within(tenant) { People.timeline(ana, day: t0 + 9.minutes) }
      expect(moves.map { |m| m["kind"] }.last(2)).to eq(%w[left arrived])
      expect(moves.last).to include("zone" => "Casa", "from" => "Fora")
    end

    it "sem tolerância (pessoa antiga) continua saindo na hora" do
      net = net_point(true)
      ana = helper("person", "name" => "Ana", "sources" => [ net.id ])
      within(tenant) { net.report!(false) }
      expect(ana.reload.value).to eq("Fora")
    end

    it "cômodo pelo ESPresense, confiança dos rastreadores e a ordem sugerida" do
      room = within(tenant) do
        create(:point, site: site, device: create(:device, site: site, name: "Chaveiro"), name: "Cômodo", capability: "text",
                       value: "Sala", writable: false, address: { "tracker" => "room" })
      end
      net = net_point(true)
      ana = helper("person", "name" => "Ana", "sources" => [ room.id, net.id ])
      expect(ana.attrs).to include("room" => "Sala")
      expect(within(tenant) { People.summary(site) }.first).to include("room" => "Sala")
      expect(within(tenant) { People.by_confidence([ room, net ]) }).to eq([ net, room ])
      expect(People::Trackers::Gps.confidence).to eq("high")
      expect(within(tenant) { People.opinions(ana) }.map { |o| o["zone"] }).to eq(%w[Casa Casa])

      within(tenant) { room.report!(Espresense::AWAY) }
      expect(ana.reload.attrs).not_to have_key("room")
    end

    it "condição Pessoa na zona" do
      net = net_point(true)
      ana = helper("person", "name" => "Ana", "sources" => [ net.id ])
      home = within(tenant) { HelperTypes::Zone.home(site) }
      ctx = Struct.new(:dummy) { def value(p) = p.value }.new(nil)
      ev = Struct.new(:ctx) { def point!(id) = Point.find(id) }.new(ctx)
      plugin = Automations::ConditionTypes::PersonCondition
      within(tenant) do
        expect(plugin.check(ev, { "point" => ana.id, "zone" => home.id, "state" => "in" }).first).to be(true)
        expect(plugin.check(ev, { "point" => ana.id, "zone" => home.id, "state" => "out" }).first).to be(false)
      end
      expect(Automations::ConditionTypes.plugins.map(&:key)).to include("person") if Automations::ConditionTypes.respond_to?(:plugins)
    end

    it "tela Pessoas, assistente do celular e o card 'Quem está em casa'" do
      resident = create(:user, tenant: tenant, name: "Kadidja Teste", role: "member")
      within(tenant) { create(:site_membership, site: site, user: resident, role: "resident") }
      phone = within(tenant) { Integrations::MobileAppPlugin.register!(site, resident, install_id: "teste12345", name: "Celular Teste") }
      login(owner)

      get "/pessoas", params: { site_id: site.id }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Presença pelo celular", "Kadidja Teste", "Falta ligar a localização")

      within(tenant) { Integrations::MobileAppPlugin.report!(phone, "location" => { "latitude" => 1.0, "longitude" => 1.0, "accuracy" => 10 }, "wifi" => "Rede Teste") }
      post "/pessoas", params: { site_id: site.id, user_id: resident.id }
      person = within(tenant) { People.persons(site).find_by(name: "Kadidja") }
      expect(response).to redirect_to(%r{/pessoas})
      expect(person).to have_attributes(value: "Casa")
      expect(person.address).to include("user_id" => resident.id, "away_delay_s" => People::AWAY_DELAY_S)
      expect(within(tenant) { HelperTypes::Person.sources(person).first.device_class }).to eq("location")

      post "/pessoas", params: { site_id: site.id, user_id: resident.id } # de novo: não duplica
      expect(within(tenant) { People.persons(site).count }).to eq(1)

      get "/pessoas", params: { site_id: site.id }
      expect(response.body).to include("Kadidja", "Hoje", "Chegou em Casa", "confiança alta")

      get "/paineis/adicionar", params: { tipo: "people", id: site.id }
      expect(response).to have_http_status(:ok)
      expect(within(tenant) { Dashboards::AddTo.widget("people", site) }).to include("type" => "people", "label" => "Quem está em casa")
    end

    it "operador não vê a tela Pessoas e não cria pessoa" do
      op = create(:user, tenant: tenant, role: "member")
      within(tenant) { create(:site_membership, site: site, user: op, role: "operator") }
      login(op)
      get "/pessoas", params: { site_id: site.id }
      expect(response.status).to be_in([ 302, 403 ])
      expect(flash[:alert]).to be_present
      post "/pessoas", params: { site_id: site.id, user_id: op.id }
      expect(within(tenant) { People.persons(site).count }).to eq(0)
    end
  end

  describe "energia" do
    let(:now) { zone.parse("2026-10-28 04:20") }

    def power(device)
      within(tenant) do
        create(:point, device: create(:device, site: site, name: device), name: "Potência", key: "#{device.parameterize(separator: "_")}.potencia",
                       capability: "measure", data_type: "decimal", unit: "W", value: 0)
      end
    end

    def rollup!(point, at, watts)
      ReadingRollup.insert_all!([ { point_id: point.id, bucket: "1h", starts_at: at.utc, min: watts, max: watts, avg: watts, last: watts, count: 1 } ])
    end

    it "custo por aparelho pela tarifa do local, ranking e comparação com o mês anterior" do
      pump = power("Bomba Teste")
      fridge = power("Geladeira Teste")
      rollup!(pump, now.change(hour: 1), 2000)      # 2 kWh
      rollup!(fridge, now.change(hour: 2), 1000)    # 1 kWh
      rollup!(pump, now.change(hour: 1) - 1.month, 1000) # mês anterior, mesmo trecho
      within(tenant) { site.update!(settings: { "energy" => { "tariff" => 0.5 } }) }

      r = travel_to(now) { within(tenant) { EnergyUse.report(site, period: "month") } }
      expect(r["rows"].map { |x| x["name"] }).to eq([ "Bomba Teste", "Geladeira Teste" ])
      expect(r["rows"].first).to include("kwh" => 2.0, "cost" => 1.0, "prev_kwh" => 1.0, "delta_pct" => 100)
      expect(r).to include("priced" => true, "total_kwh" => 3.0, "total_cost" => 1.5)

      login(owner)
      travel_to(now) { get "/energia", params: { site_id: site.id, periodo: "month" } }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Bomba Teste", "Ranking por aparelho", "+100%")

      # Card "Gasto do mês por aparelho": energy_breakdown pelo custo, com a tarifa do local.
      w = within(tenant) { Dashboards::AddTo.widget("energy_month", site) }
      expect(w).to include("type" => "energy_breakdown", "metric" => "cost", "period" => "month")
      expect(Dashboards::Widgets::EnergyBreakdownWidget.errors(w)).to eq([])
      expect(Dashboards::Widgets::EnergyBreakdownWidget.errors(w.merge("metric" => "x"))).not_to be_empty
      d = travel_to(now) { within(tenant) { Dashboards::Widgets::EnergyBreakdownWidget.data(Dashboards::Resolver.new(Dashboard.ensure_for(site).first, role: "owner"), w, []).first } }
      expect(d).to include("metric" => "cost", "total_cost" => 1.5)
    end

    it "aviso de consumo fora do normal: média aprendida por hora, um aviso agrupado por hora" do
      pump = power("Motor da piscina Teste")
      fridge = power("Geladeira Teste")
      (1..10).each do |n|
        rollup!(pump, now.change(hour: 3) - n.days, 0)       # parado de madrugada
        rollup!(fridge, now.change(hour: 3) - n.days, 100)   # 0,1 kWh por hora
      end
      rollup!(pump, now.change(hour: 3), 1500)  # 1,5 kWh às 3h: fora do normal
      rollup!(fridge, now.change(hour: 3), 110) # normal
      within(tenant) { site.update!(settings: { "energy" => { "watch" => { "enabled" => true } } }) }

      list = travel_to(now) { within(tenant) { EnergyUse.anomalies(site) } }
      expect(list.map { |a| a["name"] }).to eq([ "Motor da piscina Teste" ])
      expect(list.first).to include("kwh" => 1.5, "avg" => 0.0, "days" => 10)

      expect { travel_to(now) { EnergyWatchJob.perform_now } }.to change { within(tenant) { Notification.count } }.by(1)
      n = within(tenant) { Notification.order(:created_at).last }
      expect(n.title).to include("Motor da piscina Teste")
      expect(n.data).to include("tag" => "energia:#{site.id}", "group" => "energia")
      expect { travel_to(now) { EnergyWatchJob.perform_now } }.not_to(change { within(tenant) { Notification.count } }) # mesma hora: uma vez

      within(tenant) { site.update!(settings: { "energy" => { "watch" => { "enabled" => true, "ignore" => [ pump.device_id ] } } }) }
      expect(travel_to(now) { within(tenant) { EnergyUse.anomalies(site) } }).to be_empty

      # Pouco histórico: não avisa.
      within(tenant) { site.update!(settings: { "energy" => { "watch" => { "enabled" => true, "min_days" => 20 } } }) }
      expect(travel_to(now) { within(tenant) { EnergyUse.anomalies(site) } }).to be_empty
    end

    it "configuração pela tela: técnico+ salva; valor inválido volta com erro; operador não" do
      t = helper("number", "name" => "Tarifa Teste", "min" => "0", "max" => "10", "step" => "0.01", "unit" => "R$/kWh")
      login(owner)
      patch "/energia", params: { site_id: site.id, energy: { tariff_point: t.id, enabled: "1", factor: "3", min_kwh: "0,2" } }
      expect(response).to redirect_to(%r{/energia})
      expect(within(tenant) { EnergyUse.watch(site.reload) }).to include("enabled" => true, "factor" => 3, "min_kwh" => 0.2)
      expect(within(tenant) { EnergyUse.tariff_point(site) }).to eq(t)

      patch "/energia", params: { site_id: site.id, energy: { tariff: "abc", factor: "50" } }
      expect(flash[:alert]).to include("fator")

      op = create(:user, tenant: tenant, role: "member")
      within(tenant) { create(:site_membership, site: site, user: op, role: "operator") }
      login(op)
      patch "/energia", params: { site_id: site.id, energy: { factor: "3" } }
      expect(flash[:alert]).to be_present
      expect(within(tenant) { EnergyUse.watch(site.reload)["factor"] }).to eq(3)
      get "/energia", params: { site_id: site.id }
      expect(response).to have_http_status(:ok)
    end
  end

  it "Pessoas e Energia abrem no app pela tela do servidor (AppScreen), com o assistente e o formulário" do
    helper("person", "name" => "Ana", "sources" => [ net_point(true).id ])
    get "/api/v1/screen", params: { path: "/pessoas?site_id=#{site.id}" }, headers: auth_headers(owner)
    expect(response).to have_http_status(:ok)
    body = response.parsed_body.dig("data", "page")
    expect(body["title"]).to eq("Pessoas")
    expect(body.to_s).to include("Ana", "Presença pelo celular")

    get "/api/v1/screen", params: { path: "/energia?site_id=#{site.id}" }, headers: auth_headers(owner)
    page = response.parsed_body.dig("data", "page")
    expect(page["title"]).to eq("Energia")
    expect(page.to_s).to include("energy[factor]", "Avisar consumo fora do normal")
  end
end
