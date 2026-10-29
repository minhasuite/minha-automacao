require "rails_helper"

RSpec.describe "Histórico do ponto" do
  let(:tenant) { create(:tenant) }
  let(:device) { create(:device) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def readings(point) = Reading.where(point_id: point.id).order(:at).map { |r| [ r.value&.to_f, r.value_text ] }

  it "report! grava leitura só quando o valor muda, evento de qualidade e avisa as telas" do
    lamp = create(:point, device: device)
    stream = lamp.to_gid_param
    expect { lamp.report!(true) }.to have_broadcasted_to(stream)
    lamp.report!(true)
    lamp.report!(false, quality: "unavailable")
    lamp.report!(false)
    expect(readings(lamp)).to eq([ [ 1.0, nil ], [ 0.0, nil ] ])
    expect(lamp.events.order(:at).map(&:payload)).to eq([ { "from" => "good", "to" => "unavailable" }, { "from" => "unavailable", "to" => "good" } ])
    expect { lamp.report!(false) }.not_to have_broadcasted_to(stream)

    mode = create(:point, device: device, capability: "enum", options: %w[Casa Fora])
    mode.report!("Fora")
    expect(readings(mode)).to eq([ [ nil, "Fora" ] ])
    color = create(:point, device: device, capability: "color")
    color.report!({ "kelvin" => 3000 })
    expect(readings(color)).to eq([ [ nil, '{"kelvin":3000}' ] ])
  end

  it "respeita history none, deadband e interval" do
    quiet = create(:point, device: device, capability: "measure", history: "none")
    quiet.report!(10)
    expect(readings(quiet)).to be_empty

    temp = create(:point, device: device, capability: "measure", deadband: 0.5)
    [ 20.0, 20.3, 20.6, 19.9 ].each { |v| temp.report!(v) }
    expect(readings(temp).map(&:first)).to eq([ 20.0, 20.6, 19.9 ])

    power = create(:point, device: device, capability: "measure", history: "interval", history_interval_s: 60)
    travel_to(Time.zone.parse("2026-10-29 10:00:00")) { power.report!(100) }
    travel_to(Time.zone.parse("2026-10-29 10:00:30")) { power.report!(200) }
    travel_to(Time.zone.parse("2026-10-29 10:01:30")) { power.report!(300) }
    expect(readings(power).map(&:first)).to eq([ 100.0, 300.0 ])
  end

  it "cria as partições do mês e do seguinte e apaga as velhas" do
    Reading.ensure_partitions!(Time.utc(2024, 1, 15))
    names = -> { ActiveRecord::Base.connection.select_values("SELECT relname FROM pg_class WHERE relname LIKE 'readings_2024_%' AND relkind = 'r' ORDER BY 1") }
    expect(names.call).to eq(%w[readings_2024_01 readings_2024_02])
    Reading.drop_old_partitions!(Time.utc(2025, 2, 10))
    expect(names.call).to eq(%w[readings_2024_02])
  end
end
