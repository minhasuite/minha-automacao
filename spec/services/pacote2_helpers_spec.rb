require "rails_helper"

# Pacote 2: medidor por ciclo, integral, derivada, limite, tendência e
# mediana no grupo, todos como plugins de `HelperTypes`.
RSpec.describe "Pacote 2: helpers como os do HA" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, timezone: "America/Bogota") }
  let(:dev) { create(:device, site: site) }
  let(:src) { create(:point, device: dev, capability: "measure", unit: "kWh") }
  let(:t0) { Time.zone.parse("2026-10-11 10:00 -05:00") }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def helper(type, form = {})
    point = HelperTypes.build(site, HelperTypes.plugin(type))
    ok = HelperTypes.save(point, { "name" => "#{type} teste" }.merge(form))
    raise "não salvou: #{point.errors.full_messages}" unless ok

    point.reload
  end

  def at(time, value, point = src)
    travel_to(time) { point.report!(value) }
  end

  def cmd(point, command, value = nil) = Points::Command.call(point, command, value, source: "web", user: nil).tap { point.reload }

  describe "medidor por ciclo" do
    it "conta o consumo, sobrevive ao aparelho zerar e ao buraco de leitura, e vira o ciclo no dia de fechamento (fuso do local)" do
      at(t0, 1000)
      m = travel_to(t0) { helper("utility_meter", "source" => src.id, "cycle" => "month", "day" => "12") }
      expect(m).to have_attributes(value: 0.0, unit: "kWh", capability: "measure")
      expect(m.attrs["period_start"]).to eq("2026-09-12T00:00:00-05:00")

      at(t0 + 1.hour, 1002.5)
      expect(m.reload.value).to eq(2.5)
      at(t0 + 2.hours, 1.5) # aparelho reiniciou e zerou: 1,5 novo, nada some
      expect(m.reload.value).to eq(4.0)
      travel_to(t0 + 3.hours) { src.report!(src.value, quality: "unavailable") }
      expect(m.reload.value).to eq(4.0)
      at(t0 + 4.hours, 3.5) # voltou: a diferença entra de uma vez
      expect(m.reload.value).to eq(6.0)

      # Fuso do local (Bogotá, -5, diferente do da aplicação): 23:59 ainda é dia 11; 00:00 do dia 12 (05:00 UTC) vira o ciclo.
      HelperTypes.tick(Time.zone.parse("2026-10-11 23:59 -05:00"))
      expect(m.reload.value).to eq(6.0)
      HelperTypes.tick(Time.zone.parse("2026-10-12 00:00 -05:00"))
      m.reload
      expect(m.value).to eq(0.0)
      expect(m.attrs).to include("last_period" => 6.0, "period_start" => "2026-10-12T00:00:00-05:00")
      HelperTypes.tick(Time.zone.parse("2026-10-12 00:01 -05:00"))
      expect(m.reload.attrs["last_period"]).to eq(6.0)
      expect(Reading.where(point_id: m.id).count).to be >= 4 # vai para o histórico (rollups)
    end

    it "tarifas: a troca no meio do ciclo deixa o consumo de antes na tarifa de antes; zerar guarda o ciclo" do
      at(t0, 100)
      m = travel_to(t0) { helper("utility_meter", "source" => src.id, "cycle" => "day", "tariffs_text" => "Ponta, Fora de ponta") }
      expect(HelperTypes::UtilityMeter.commands(m)).to eq(%w[reset select])
      at(t0 + 1.minute, 101)
      travel_to(t0 + 2.minutes) { src.update_column(:value, 103) } # leitura ainda não processada
      travel_to(t0 + 2.minutes) { cmd(m, "select", "Fora de ponta") }
      expect(m.attrs).to include("tariff" => "Fora de ponta", "tariffs" => { "Ponta" => 3.0, "Fora de ponta" => 0.0 })
      at(t0 + 3.minutes, 107)
      expect(m.reload.attrs["tariffs"]).to eq("Ponta" => 3.0, "Fora de ponta" => 4.0)
      expect(m.value).to eq(7.0)
      expect { cmd(m, "select", "Feriado") }.to raise_error(Points::Command::Error)
      travel_to(t0 + 4.minutes) { cmd(m, "reset") }
      expect(m).to have_attributes(value: 0.0)
      expect(m.attrs).to include("last_period" => 7.0, "tariffs" => { "Ponta" => 0.0, "Fora de ponta" => 0.0 })
      expect { HelperTypes::UtilityMeter.check(m, 5) }.to raise_error(Points::Command::Error)
    end

    it "cron próprio e validação" do
      m = helper("utility_meter", "source" => src.id, "cycle" => "cron", "cron" => "30 6 * * 1")
      expect(HelperTypes::UtilityMeter.period_start(m, Time.zone.parse("2026-10-14 12:00 -05:00"))).to eq(Time.zone.parse("2026-10-12 06:30 -05:00"))
      expect(HelperTypes::UtilityMeter.summary(m)).to include("30 6 * * 1")
      bad = HelperTypes.build(site, HelperTypes::UtilityMeter)
      expect(HelperTypes.save(bad, "name" => "x", "source" => src.id, "cycle" => "cron", "cron" => "toda hora")).to be false
      expect(HelperTypes.save(bad, "name" => "x", "source" => src.id, "cycle" => "month", "day" => "31")).to be false
    end
  end

  describe "integral" do
    let(:power) { create(:point, device: dev, capability: "measure", unit: "W") }

    it "W → kWh: trapezoidal, esquerda e direita; buraco de leitura não entra; intervalo máximo integra parado" do
      at(t0, 1000, power)
      trap, left, right = %w[trapezoidal left right].map do |m|
        travel_to(t0) { helper("integral", "name" => "int #{m}", "source" => power.id, "method" => m, "prefix" => "k", "time_unit" => "h", "round" => "3") }
      end
      expect(trap).to have_attributes(unit: "kWh", value: 0.0)
      at(t0 + 1.hour, 3000, power)
      expect([ trap, left, right ].map { |p| p.reload.value }).to eq([ 2.0, 1.0, 3.0 ])

      travel_to(t0 + 2.hours) { power.report!(3000, quality: "unavailable") }
      at(t0 + 5.hours, 3000, power) # 3 h fora do ar: não conta
      expect(trap.reload.value).to eq(2.0)

      maxed = travel_to(t0 + 5.hours) { helper("integral", "name" => "int max", "source" => power.id, "method" => "left", "prefix" => "k", "max_interval" => "30m") }
      HelperTypes.tick(t0 + 5.hours + 20.minutes)
      expect(maxed.reload.value).to eq(0.0)
      HelperTypes.tick(t0 + 5.hours + 30.minutes)
      expect(maxed.reload.value).to eq(1.5)
      expect(HelperTypes::Integral.summary(maxed)).to include("kWh", "30 min")
    end
  end

  describe "derivada" do
    it "taxa entre as duas últimas leituras ou na janela, com unidade" do
      temp = create(:point, device: dev, capability: "measure", unit: "°C")
      at(t0, 20, temp)
      d = travel_to(t0) { helper("derivative", "source" => temp.id, "time_unit" => "h", "round" => "2") }
      expect(d.unit).to eq("°C/h")
      expect(d.value).to be_nil
      at(t0 + 30.minutes, 21, temp)
      expect(d.reload.value).to eq(2.0)
      w = travel_to(t0 + 30.minutes) { helper("derivative", "name" => "janela", "source" => temp.id, "window" => "1h") }
      at(t0 + 40.minutes, 22, temp)
      at(t0 + 50.minutes, 24, temp)
      expect(w.reload.value).to eq(9.0) # 21 → 24 em 20 min
      expect(d.reload.value).to eq(12.0) # 22 → 24 em 10 min
    end
  end

  describe "limite" do
    it "acima, abaixo e faixa, com histerese" do
      at(t0, 50)
      up = helper("threshold", "name" => "acima", "source" => src.id, "upper" => "70", "hysteresis" => "2")
      down = helper("threshold", "name" => "abaixo", "source" => src.id, "lower" => "20")
      band = helper("threshold", "name" => "faixa", "source" => src.id, "lower" => "40", "upper" => "60")
      expect([ up, down, band ].map(&:value)).to eq([ false, false, true ])
      at(t0 + 1.minute, 71) # dentro da histerese: fica
      expect(up.reload.value).to be false
      at(t0 + 2.minutes, 73)
      expect(up.reload).to have_attributes(value: true, attrs: { "position" => "above" })
      at(t0 + 3.minutes, 69) # ainda na histerese: continua ligado
      expect(up.reload.value).to be true
      at(t0 + 4.minutes, 67)
      expect(up.reload.value).to be false
      expect(band.reload.value).to be false
      at(t0 + 5.minutes, 10)
      expect(down.reload.value).to be true
      travel_to(t0 + 6.minutes) { src.report!(10, quality: "unavailable") }
      expect(down.reload.quality).to eq("unavailable")
      bad = HelperTypes.build(site, HelperTypes::Threshold)
      expect(HelperTypes.save(bad, "name" => "x", "source" => src.id)).to be false
      expect(HelperTypes.save(bad, "name" => "x", "source" => src.id, "lower" => "9", "upper" => "3")).to be false
    end
  end

  describe "tendência" do
    it "liga subindo (ou descendo, invertido) com mínimo de amostras" do
      at(t0, 10)
      up = travel_to(t0) { helper("trend", "source" => src.id, "min_samples" => "3", "max_samples" => "5") }
      down = travel_to(t0) { helper("trend", "name" => "desce", "source" => src.id, "invert" => "1", "max_samples" => "3") }
      expect(up.quality).to eq("unavailable")
      at(t0 + 1.minute, 11)
      expect(up.reload.quality).to eq("unavailable")
      at(t0 + 2.minutes, 12)
      expect(up.reload).to have_attributes(value: true, quality: "good")
      expect(up.attrs["samples"]).to eq(3)
      expect(down.reload.value).to be false
      at(t0 + 3.minutes, 5)
      at(t0 + 4.minutes, 1)
      expect(down.reload.value).to be true
    end
  end

  it "grupo e estatística: mediana" do
    others = [ 1, 7, 3, 100 ].map { |v| create(:point, device: dev, capability: "measure").tap { |p| p.report!(v) } }
    g = helper("group", "members" => others.map(&:id), "mode" => "median")
    expect(g.value).to eq(5.0)
  end

  it "aberto para extensão: tipo novo com relógio entra só pelo registro" do
    fake = Class.new(HelperTypes::Plugin) do
      describe key: "fake_clock", title: "Relógio falso", icon: "clock", capability: "measure", description: "Teste"
      def self.clocked? = true
      def self.tick(point, now) = point.report!(now.min)
    end
    stub_const("HelperTypes::FakeClock", fake)
    stub_const("HelperTypes::PLUGINS", HelperTypes::PLUGINS + %w[FakeClock])
    p = HelperTypes.build(site, fake)
    p.update!(name: "Falso", key: "helpers.falso")
    HelperTypes.tick(Time.zone.parse("2026-10-30 10:07"))
    expect(p.reload.value).to eq(7)
  end
end
