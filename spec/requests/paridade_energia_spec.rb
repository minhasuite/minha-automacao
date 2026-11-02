require "rails_helper"

# Painel de Energia completo (paridade com o HA) só com plugins: helper
# Tarifa (tarifa branca), widgets energy_flow/energy_breakdown/energy_compare
# e a predefinição "Energia" (Dashboards::Presets, extensível por stub_const).
RSpec.describe "Painel de Energia" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa Teste") } }
  let(:now) { Time.find_zone("America/Sao_Paulo").parse("2026-10-28 22:30") } # quarta-feira

  def power(name, device, value = 0, unit: "W")
    within(tenant) do
      create(:point, device: create(:device, site: site, name: device), name: name, key: "#{device.parameterize}.#{name.parameterize}",
                     capability: "measure", data_type: "decimal", unit: unit, value: value)
    end
  end

  def rollup!(point, hour, avg_w)
    at = now.change(hour: hour).utc
    ReadingRollup.insert_all!([ { point_id: point.id, bucket: "1h", starts_at: at, min: avg_w, max: avg_w, avg: avg_w, last: avg_w, count: 1 } ])
  end

  def tariff!
    within(tenant) do
      point = HelperTypes.build(site, HelperTypes::Tariff)
      expect(HelperTypes.save(point, "name" => "Teste tarifa branca", "base" => "0,65", "bands" => HelperTypes::Tariff::WHITE, "weekdays_only" => "1")).to be(true)
      point
    end
  end

  before { post("/entrar", params: { email: user.email, password: "12345678" }) }

  it "helper Tarifa: preço por horário (ponta, intermediária, fora de ponta, fim de semana) e faixa inválida" do
    t = tariff!
    plugin = HelperTypes::Tariff
    expect(plugin.price_at(t, now.change(hour: 19))).to eq(1.35)
    expect(plugin.price_at(t, now.change(hour: 17, min: 30))).to eq(0.92)
    expect(plugin.price_at(t, now.change(hour: 21, min: 59))).to eq(0.92)
    expect(plugin.price_at(t, now.change(hour: 10))).to eq(0.65)
    expect(plugin.price_at(t, now.change(day: 31, hour: 19))).to eq(0.65) # sábado
    travel_to(now.change(hour: 19)) { within(tenant) { plugin.tick(t, Time.current) } }
    expect(t.reload.value).to eq(1.35)
    expect(t.attrs["band"]).to eq("Ponta")
    expect(plugin.value_text(t)).to eq("R$ 1,35/kWh · Ponta")
    expect(plugin.summary(t)).to include("3 faixa(s)")
    expect(plugin.parse("Noite 22:00-05:00 = 0,5\nqualquer coisa").then { |b, bad| [ b.first["from"], bad ] }).to eq([ "22:00", [ "qualquer coisa" ] ])

    bad = within(tenant) { HelperTypes.build(site, plugin) }
    expect(within(tenant) { HelperTypes.save(bad, "name" => "Teste ruim", "base" => "", "bands" => "18h às 21h") }).to be(false)
    expect(bad.errors.full_messages.join).to include("preço base", "Faixa que não entendi")
  end

  it "custo hora a hora com a tarifa branca no widget energy" do
    t = tariff!
    p = power("Potência", "Quadro")
    rollup!(p, 10, 1000) # 1 kWh fora de ponta
    rollup!(p, 18, 1000) # 1 kWh na ponta
    data = travel_to(now) { within(tenant) { Dashboards::Energy.new({ "period" => "today" }, [ p ], site, tariff_point: t).call } }
    expect(data["kwh"]).to eq(2.0)
    expect(data["cost"]).to eq(2.0) # 0,65 + 1,35
    fixed = travel_to(now) { within(tenant) { Dashboards::Energy.new({ "period" => "today", "tariff" => 0.8 }, [ p ], site).call } }
    expect(fixed["cost"]).to eq(1.6)
  end

  it "fluxo divide a potência como o HA (solar → casa → bateria → rede)" do
    split = Dashboards::Widgets::EnergyFlowWidget.method(:split)
    expect(split.(grid: -1000, solar: 3000)).to include("home" => 2000, "solar_home" => 2000, "solar_grid" => 1000, "grid_home" => 0)
    expect(split.(grid: 200, solar: 1000, battery: -500)).to include("home" => 700, "solar_home" => 700, "solar_battery" => 300, "grid_battery" => 200, "grid_home" => 0)
    expect(split.(grid: 300, battery: 400)).to include("home" => 700, "battery_home" => 400, "grid_home" => 300)
    expect(Dashboards::Widgets::EnergyFlowWidget.errors({})).to include("informe ao menos a rede ou o solar")
  end

  it "predefinição Energia monta o painel com fluxo, mês, comparação, ranking e gráfico" do
    grid = power("Rede", "Medidor", 1500)
    solar = power("Solar", "Inversor", 2.1, unit: "kW")
    tv = power("Consumo", "TV")
    geladeira = power("Consumo", "Geladeira")
    rollup!(tv, 10, 300)
    rollup!(geladeira, 10, 100)
    t = tariff!

    get "/locais/#{site.id}/paineis/prontos"
    expect(response.body).to include("Painel pronto", "Energia", "/locais/#{site.id}/paineis/prontos/energy")
    get "/locais/#{site.id}/paineis/prontos/energy"
    expect(response.body).to include("Potência da rede", "Medidores de consumo", "Rede · Medidor").and(include("Teste tarifa branca"))

    travel_to(now) do
      post "/locais/#{site.id}/paineis/prontos/energy",
           params: { preset: { name: "Teste energia", grid: grid.id, solar: solar.id, consumption: [ tv.id, geladeira.id ], tariff_point: t.id, goal: "300" } }
    end
    d = within(tenant) { Dashboard.find_by!(name: "Teste energia") }
    expect(response).to redirect_to("/paineis/#{d.id}")
    types = d.definition["views"].first["sections"].flat_map { |s| s["widgets"].pluck("type") }
    expect(types).to eq(%w[energy_flow energy energy energy_compare energy_breakdown chart])
    expect(Dashboards::Schema.errors(d.definition)).to eq([])

    travel_to(now) { get "/paineis/#{d.id}" }
    body = response.body
    expect(body).to include("Energia agora", "ef-flow", "Comprando", "2,1 kW", "Consumo por aparelho", "Comparação de consumo", "Esta semana", "Este mês")
    expect(body.index(">TV<")).to be < body.index(">Geladeira<") # ranking: a TV gastou mais

    resolved = travel_to(now) { within(tenant) { Dashboards::Resolver.new(d, role: "owner").call } }
    rank = resolved["views"].first["sections"].flat_map { |s| s["widgets"] }.find { |w| w["type"] == "energy_breakdown" }["data"]
    expect(rank["rows"].pluck("name")).to eq(%w[TV Geladeira])
    expect(rank["rows"].first).to include("kwh" => 0.3, "pct" => 75.0, "cost" => 0.2) # 0,3 kWh × 0,65
  end

  it "predefinição sem ponto válido não cria e explica" do
    post "/locais/#{site.id}/paineis/prontos/energy", params: { preset: { name: "Teste vazio" } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(within(tenant) { Dashboard.where(name: "Teste vazio").count }).to eq(0)
  end

  it "predefinição nova por stub_const entra na tela e cria o painel sem mudar o núcleo" do
    fake = Class.new(Dashboards::Presets::Base) do
      describe key: "falsa", title: "Teste falsa", icon: "star", description: "Só um título."
      fields [ { key: "titulo", label: "Título", kind: :text } ]
      def self.build(_site, form)
        { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ section("s", "S", "star", [ widget("h", "heading", title: form[:titulo]) ]) ] } ] }
      end
    end
    stub_const("Dashboards::Presets::Falsa", fake)
    stub_const("Dashboards::Presets::PLUGINS", Dashboards::Presets::PLUGINS + %w[Falsa])
    get "/locais/#{site.id}/paineis/prontos"
    expect(response.body).to include("Teste falsa", "Só um título.")
    post "/locais/#{site.id}/paineis/prontos/falsa", params: { preset: { titulo: "Olá" } }
    d = within(tenant) { Dashboard.find_by!(name: "Teste falsa") }
    expect(d.definition.dig("views", 0, "sections", 0, "widgets", 0)).to include("type" => "heading", "title" => "Olá")
  end

  it "widgets novos aparecem no editor com o formulário próprio" do
    d = within(tenant) { Dashboard.ensure_for(site).first }
    get "/paineis/#{d.id}/editar"
    expect(response.body).to include(">Fluxo de energia</option>", ">Consumo por aparelho</option>", ">Comparação de consumo</option>",
                                     "widget[grid_invert]", "widget[limit]")
  end
end
