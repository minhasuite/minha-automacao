require "rails_helper"

# Sensor que declara humidity_value e manda va_humidity (10/11/2026): o ponto
# usa o código que chega no estado (`aliases` do tuya.yml).
RSpec.describe Tuya::Cloud do
  def rel(dp, code) = { "dpId" => dp, "statusCode" => code, "valueType" => "Integer", "valueDesc" => "{}" }

  it "troca o código declarado pelo equivalente que vem no estado" do
    out = described_class.aliased([ rel(1, "va_temperature"), rel(2, "humidity_value"), rel(4, "battery_percentage") ],
                                  { "va_temperature" => 324, "va_humidity" => 476, "battery_percentage" => 51 })
    expect(out.map { |r| r["statusCode"] }).to eq(%w[va_temperature va_humidity battery_percentage])
  end

  it "mantém o declarado quando ele vem no estado, sem estado ou quando o equivalente já tem dono" do
    rels = [ rel(2, "humidity_value") ]
    expect(described_class.aliased(rels, { "humidity_value" => 40 })).to eq(rels)
    expect(described_class.aliased(rels, {})).to eq(rels)
    both = [ rel(2, "humidity_value"), rel(3, "va_humidity") ]
    expect(described_class.aliased(both, { "va_humidity" => 1 }).map { |r| r["statusCode"] }).to eq(%w[humidity_value va_humidity])
  end
end
