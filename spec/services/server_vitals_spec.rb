require "rails_helper"

# Sinais vitais do servidor (24/11/2026): temperatura pelos sensores, e as quedas (rede, desligado) e o calor
# virando aviso ao dono. Estado num arquivo temporário; nada sai para a rede (online/temp entram no tick).
RSpec.describe ServerVitals do
  let!(:owner) { create(:user) }
  let(:dir) { Pathname(Dir.mktmpdir) }
  let(:t0) { Time.zone.parse("2026-11-17 18:40 -03:00") }

  before { allow(described_class).to receive(:path).and_return(dir.join("server-vitals.json")) }
  after { FileUtils.rm_rf(dir) }

  def notices = ActsAsTenant.without_tenant { Notification.where(kind: "sistema").order(:created_at).pluck(:title) }

  it "temperatura: o maior sensor de CPU conhecido; sem sensor, a zona térmica (Raspberry Pi); nada = nil" do
    sys = dir.join("sys")
    { "hwmon0" => [ "coretemp", 53_000, 61_000 ], "hwmon1" => [ "BAT0", 99_000 ], "hwmon2" => [ "acpitz", 58_000 ] }.each do |h, (name, *temps)|
      FileUtils.mkdir_p(sys.join("class/hwmon", h))
      File.write(sys.join("class/hwmon", h, "name"), "#{name}\n")
      temps.each_with_index { |t, i| File.write(sys.join("class/hwmon", h, "temp#{i + 1}_input"), t.to_s) }
    end
    expect(described_class.temperature(sys.to_s)).to eq(61) # a bateria (99 °C) não conta
    pi = dir.join("pi")
    FileUtils.mkdir_p(pi.join("class/thermal/thermal_zone0"))
    File.write(pi.join("class/thermal/thermal_zone0/temp"), "47234")
    expect(described_class.temperature(pi.to_s)).to eq(47)
    expect(described_class.temperature(dir.join("vazio").to_s)).to be_nil
    expect([ 3600, 285 * 60, 90, 30, 90_000 ].map { |x| described_class.duration(x) }).to eq([ "1 h", "4 h 45 min", "1 min", "1 min", "1 d 1 h" ])
    expect([ described_class.level(61), described_class.level(88), described_class.level(97), described_class.level(nil) ]).to eq(%w[ok warn error ok])
  end

  it "sem internet: avisa ao voltar, com a duração; queda curta não avisa" do
    described_class.tick(now: t0, online: true, temp: 55)
    described_class.tick(now: t0 + 1.minute, online: false, temp: 55)
    described_class.tick(now: t0 + 2.minutes, online: true, temp: 55) # 1 min: um pacote perdido
    expect(notices).to be_empty
    (6..290).each { |m| described_class.tick(now: t0 + m.minutes, online: false, temp: 55) } # o worker segue batendo
    s = described_class.tick(now: t0 + 291.minutes, online: true, temp: 55)
    expect(notices).to eq([ "O servidor ficou sem internet por 4 h 45 min" ])
    expect(s["last_outage"]).to include("seconds" => 285 * 60)
    expect(described_class.last_outage_text).to include("Sem internet por 4 h 45 min")
  end

  it "desligado: batimento parado mais de 5 min vira aviso no primeiro tick depois de ligar" do
    described_class.tick(now: t0, online: true, temp: 55)
    described_class.tick(now: t0 + 3.minutes, online: true, temp: 55) # deploy: o worker reiniciou rápido
    expect(notices).to be_empty
    described_class.tick(now: t0 + 79.minutes, online: true, temp: 55)
    expect(notices).to eq([ "O servidor ficou desligado por 1 h 16 min" ])
    expect(described_class.last_outage["kind"]).to eq("off")
  end

  it "quente: 2 minutos seguidos no limite viram um aviso, e no máximo um por hora" do
    [ 96, 97, 98, 99 ].each_with_index { |t, i| described_class.tick(now: t0 + i.minutes, online: true, temp: t) }
    expect(notices).to eq([ "Servidor quente: 97 °C" ])
    (4..59).each { |m| described_class.tick(now: t0 + m.minutes, online: true, temp: 98) }
    expect(notices.size).to eq(1) # ainda dentro da hora
    described_class.tick(now: t0 + 61.minutes, online: true, temp: 98)
    expect(notices.size).to eq(2)
    described_class.tick(now: t0 + 62.minutes, online: true, temp: 70)
    expect(described_class.state["hot_ticks"]).to eq(0)
  end

  it "Saúde e integração Sistema mostram temperatura, internet e a última queda" do
    described_class.tick(now: 10.minutes.ago, online: false, temp: 60)
    described_class.tick(now: Time.current, online: true, temp: 60)
    allow(described_class).to receive(:temperature).and_return(88)
    items = Health::Checks::Server.items(owner.tenant).index_by(&:key)
    expect(items["temp"].status).to eq("warn")
    expect(items["internet"].status).to eq("ok")
    expect(items["outage"]).to have_attributes(status: "warn")
    expect(Integrations::SystemPlugin::METRICS.keys).to include("cpu_temp", "offline", "last_outage")
    expect(Health::CHECKS).to include("Server")
  end
end
