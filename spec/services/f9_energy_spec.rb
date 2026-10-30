require "rails_helper"

RSpec.describe "F9: widget Consumo e custo (energy)" do
  include ActiveSupport::Testing::TimeHelpers

  let(:tenant) { create(:tenant) }
  let(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Medidor") } }
  let!(:power) { within(tenant) { create(:point, device: device, site: site, name: "Potência", key: "quadro.potencia", capability: "measure", unit: "W", value: 1000) } }
  let!(:meter) { within(tenant) { create(:point, device: device, site: site, name: "Energia", key: "quadro.energia", capability: "measure", unit: "kWh", device_class: "energy", value: 0) } }
  let(:zone) { ActiveSupport::TimeZone["America/Sao_Paulo"] }
  let(:now) { zone.parse("2026-10-15 14:30") }

  around { |ex| ActsAsTenant.with_tenant(tenant) { travel_to(now) { ex.run } } }

  # Uma linha de rollup por hora de `from` até `to` (exclusivo).
  def hours(point, from, to, &value)
    rows = []
    t = from
    i = 0
    while t < to
      v = value.call(i)
      rows << { point_id: point.id, bucket: "1h", starts_at: t.utc, min: v, max: v, avg: v, sum: v, last: v, count: 1 }
      t += 1.hour
      i += 1
    end
    ReadingRollup.upsert_all(rows, unique_by: %i[point_id bucket starts_at])
  end

  def energy(w, points = [ power ], tariff_point: nil) = Dashboards::Energy.new(w, points, site, tariff_point: tariff_point).call

  it "potência (W): soma as horas do mês, completa com o valor atual, custo, projeção, meta e barras por dia" do
    hours(power, zone.parse("2026-09-01"), now.beginning_of_hour + 1.hour) { 1000 } # a hora corrente (parcial) é ignorada
    d = energy({ "period" => "month", "tariff" => 0.9, "goal" => 600, "compare" => true })
    expect(d["kwh"]).to eq(350.5) # 14 dias × 24 h + 14 h + meia hora pelo valor atual
    expect(d["cost"]).to eq(315.45)
    expect(d["projection_kwh"]).to be_within(1).of(744)
    expect(d["projection_cost"]).to be_within(1).of(744 * 0.9)
    expect(d["goal_ratio"]).to be > 1
    expect(d["previous_kwh"]).to eq(351) # setembro até o mesmo trecho (a hora das 14h entra inteira)
    expect(d["delta_pct"]).to eq(0)
    expect(d["bars"].size).to eq(31)
    expect(d["bars"].first).to include("label" => "01", "kwh" => 24.0)
    expect(d["bars"][14]["kwh"]).to eq(14.5)
    expect(d["bars"][15]["kwh"]).to be_nil
    expect(d["period_label"]).to eq("01/10 a 31/10")
  end

  it "medidor (kWh acumulado): diferença das horas, volta do medidor, hoje por hora e tarifa por ponto" do
    hours(meter, now.beginning_of_day - 1.hour, now.beginning_of_hour) { |i| i == 10 ? 1 : 100 + (2 * i) } # zerou às 9h
    meter.update!(value: 30)
    tarifa = create(:point, device: device, site: site, name: "Tarifa", capability: "setpoint", value: 1.25)
    d = energy({ "period" => "today", "tariff_point" => tarifa.id }, [ meter ], tariff_point: tarifa)
    # 00h–08h: 2/h (18), 09h: zerou (conta 1), 10h: 122 − 1 = 121, 11h–13h: 2/h (6), agora: 30 − 128 < 0 → 0
    expect(d["kwh"]).to eq(18 + 1 + 121 + 6)
    expect(d["tariff"]).to eq(1.25)
    expect(d["cost"]).to eq(182.5)
    expect(d["bars"].size).to eq(24)
    expect(d["bars"][0]).to include("label" => "00", "kwh" => 2.0)
    expect(d["period_label"]).to eq("Hoje")
  end

  it "semana e ciclo com dia de corte; sem ponto suportado = missing; sem tarifa = sem custo" do
    d = energy({ "period" => "week" })
    expect(Time.zone.parse(d["from"]).in_time_zone(zone).to_date).to eq(Date.new(2026, 10, 12))
    expect(d["bars"].size).to eq(7)
    expect(d["cost"]).to be_nil
    expect(energy({ "period" => "cycle", "cycle_day" => 20 })["period_label"]).to eq("20/09 a 19/10")
    expect(energy({ "period" => "cycle", "cycle_day" => 10 })["period_label"]).to eq("10/10 a 09/11")
    lamp = create(:point, device: device, site: site, name: "Luz")
    expect(energy({}, [ lamp ])).to include("missing" => true, "kwh" => 0.0)
    power.update!(quality: "unavailable")
    expect(energy({ "period" => "today" })["kwh"]).to eq(0.0)
  end

  it "schema valida as props e o resolver devolve os dados com a tarifa como dependência" do
    ok = { "id" => "e1", "type" => "energy", "binds" => [ power.id ], "period" => "cycle", "cycle_day" => 5, "tariff" => 0.8, "goal" => 300, "compare" => true }
    bad = { "id" => "e2", "type" => "energy", "binds" => [ power.id ], "period" => "ano", "cycle_day" => 31, "tariff" => -1, "tariff_point" => 3, "goal" => 0, "compare" => "sim" }
    defn = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "Casa", "sections" => [ { "id" => "s", "widgets" => [ ok ] } ] } ] }
    expect(Dashboards::Schema.errors(defn)).to eq([])
    defn["views"][0]["sections"][0]["widgets"] << bad
    expect(Dashboards::Schema.errors(defn).join("\n")).to include("period inválido", "cycle_day", "tariff precisa", "tariff_point", "goal", "compare")

    tarifa = create(:point, device: device, site: site, name: "Tarifa", capability: "setpoint", value: 0.7)
    defn["views"][0]["sections"][0]["widgets"] = [ ok.merge("tariff_point" => tarifa.key) ]
    dashboard = Dashboard.create!(site: site, name: "Energia", definition: defn)
    w = Dashboards::Resolver.new(dashboard, role: "owner").call["views"][0]["sections"][0]["widgets"][0]
    expect(w["data"]).to include("tariff" => 0.7, "point_ids" => [ power.id ])
    expect(w["deps"]).to contain_exactly(power.id, tarifa.id)
  end
end
