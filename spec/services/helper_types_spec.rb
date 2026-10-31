require "rails_helper"

RSpec.describe HelperTypes do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def helper(type, form = {})
    point = described_class.build(site, described_class.plugin(type))
    ok = described_class.save(point, { "name" => "#{type} 1" }.merge(form))
    raise "não salvou: #{point.errors.full_messages}" unless ok

    point.reload
  end

  def cmd(point, command, value = nil) = Points::Command.call(point, command, value, source: "web", user: nil).tap { point.reload }

  def expect_invalid(point, command, value = nil)
    expect { cmd(point, command, value) }.to raise_error(Points::Command::Error)
  end

  it "catálogo: todo plugin tem chave, título, ícone existente, descrição e partial" do
    expect(described_class.keys).to eq(%w[toggle number select text datetime button counter timer group template statistics dataset_query utility_meter integral derivative threshold trend zone person alarm_panel])
    described_class.plugins.each do |p|
      expect([ p.title, p.description ]).to all(be_present)
      expect(HelperTypes::ICONS).to include(p.icon)
      expect(Rails.root.join("app/views/web/site_helpers/forms/_#{p.key}.html.erb")).to exist
    end
  end

  it "cria no dispositivo virtual Helpers do local, com chave única e valor inicial" do
    a = helper("toggle", "initial" => "1", "icon" => "home")
    b = helper("toggle", "name" => "toggle 1", "icon" => "nao-existe")
    expect(a.device).to have_attributes(driver: "virtual", external_id: "helpers", name: "Helpers")
    expect(b.device).to eq(a.device)
    expect([ a.key, b.key ]).to eq(%w[helpers.toggle_1 helpers.toggle_1_2])
    expect(a.value).to be true
    expect(a.icon).to eq("home")
    expect(b.icon).to be_nil
    expect(b.value).to be false
    expect(cmd(b, "toggle").point.value).to be true
  end

  it "número: faixa e passo; texto: tamanho, padrão e senha" do
    n = helper("number", "min" => "10", "max" => "30", "step" => "0,5", "unit" => "°C", "mode" => "box")
    expect(n).to have_attributes(value: 10.0, unit: "°C", capability: "setpoint")
    expect(n.address["mode"]).to eq("box")
    expect(cmd(n, "set", "22,5").point.value).to eq(22.5)
    expect_invalid(n, "set", "22.3")
    expect_invalid(n, "set", "31")
    expect(HelperTypes::Number.summary(n)).to include("10 a 30 °C", "passo 0.5")

    t2 = helper("text", "min" => "2", "max" => "6", "pattern" => "[0-9]+", "password" => "1")
    expect(cmd(t2, "set", "1234").point.value).to eq("1234")
    expect_invalid(t2, "set", "12a4")
    expect_invalid(t2, "set", "1")
    expect(ApplicationController.helpers.point_value_text(t2)).to eq("Oculto")
    bad = described_class.build(site, HelperTypes::Text)
    expect(described_class.save(bad, "name" => "x", "pattern" => "[")).to be false
    expect(bad.errors.full_messages.join).to include("Padrão inválido")
  end

  it "lista de opções, data e hora, botão" do
    s = helper("select", "options_text" => "Casa, Fora, Noite, Casa")
    expect(s.options).to eq(%w[Casa Fora Noite])
    expect(s.value).to eq("Casa")
    expect(cmd(s, "select", "Noite").point.value).to eq("Noite")
    expect_invalid(s, "select", "Praia")

    d = helper("datetime", "mode" => "date")
    expect(d.value).to eq(Date.current.iso8601)
    expect(cmd(d, "set", "2026-12-24").point.value).to eq("2026-12-24")
    expect(ApplicationController.helpers.point_value_text(d)).to eq("24/12/2026")
    expect_invalid(d, "set", "2026-02-31")
    expect_invalid(d, "set", "18:00")
    h = helper("datetime", "mode" => "time")
    expect(cmd(h, "set", "06:30").point.value).to eq("06:30")
    dt = helper("datetime")
    expect(cmd(dt, "set", "2026-12-24T20:00").point.value).to eq("2026-12-24T20:00")
    expect(ApplicationController.helpers.point_value_text(dt)).to eq("24/12/2026 20:00")

    b = helper("button")
    travel_to(Time.zone.parse("2026-10-30 10:00")) { cmd(b, "press") }
    first = b.value
    travel_to(Time.zone.parse("2026-10-30 10:01")) { cmd(b, "press") }
    expect(b.value).not_to eq(first)
  end

  it "contador: passo, limites, zerar e definir" do
    c = helper("counter", "initial" => "2", "step" => "3", "min" => "0", "max" => "10")
    expect(c.value).to eq(2)
    expect(cmd(c, "increment").point.value).to eq(5)
    cmd(c, "increment")
    expect(cmd(c, "increment").point.value).to eq(10)
    expect(cmd(c, "decrement").point.value).to eq(7)
    expect(cmd(c, "reset").point.value).to eq(2)
    expect(cmd(c, "set", "9").point.value).to eq(9)
    expect_invalid(c, "set", "x")
    expect_invalid(c, "on")
    expect(Points::Command.actions_for(c)).to eq(%w[decrement increment reset])
    bad = described_class.build(site, HelperTypes::Counter)
    expect(described_class.save(bad, "name" => "x", "initial" => "20", "max" => "10")).to be false
  end

  it "temporizador: inicia, pausa, retoma, cancela e termina pelo job (job velho não faz nada)" do
    t = helper("timer", "duration" => "10m")
    expect(t).to have_attributes(value: "idle", capability: "timer")
    now = Time.zone.parse("2026-10-30 10:00")
    travel_to(now) do
      expect { cmd(t, "start") }.to have_enqueued_job(HelperTimerJob)
      expect(t.value).to eq("active")
      expect(Time.zone.parse(t.address["finishes_at"])).to eq(now + 10.minutes)
    end
    old_stamp = t.address["finishes_at"]
    travel_to(now + 4.minutes) { cmd(t, "pause") }
    expect(t).to have_attributes(value: "paused")
    expect(t.address["remaining_s"]).to eq(360)
    expect(ApplicationController.helpers.point_value_text(t)).to include("faltam 6 min")
    HelperTimerJob.perform_now(t.id, old_stamp)
    expect(t.reload.value).to eq("paused")
    travel_to(now + 5.minutes) { cmd(t, "start") }
    expect(Time.zone.parse(t.address["finishes_at"])).to eq(now + 11.minutes)
    expect(ApplicationController.helpers.point_value_text(t)).to include("termina às")
    HelperTimerJob.perform_now(t.id, t.address["finishes_at"])
    expect(t.reload.value).to eq("finished")
    cmd(t, "start", "30s")
    cmd(t, "cancel")
    expect(t).to have_attributes(value: "idle")
    expect(t.address).not_to include("finishes_at")
    expect_invalid(t, "start", "abc")
    expect(Points::Command.actions_for(t)).to eq(%w[start])
    expect(described_class.save(described_class.build(site, HelperTypes::Timer), "name" => "y", "duration" => "")).to be false
  end

  it "grupo de liga/desliga: valor por todos/qualquer, comando repassado aos membros" do
    dev = create(:device, site: site)
    a = create(:point, device: dev, value: false)
    b = create(:point, device: dev, value: false, risk: "sensitive")
    g = helper("group", "members" => [ a.id, b.id ], "mode" => "any")
    expect(g).to have_attributes(capability: "onoff", writable: true, risk: "sensitive", value: false)
    cmd(a, "on")
    expect(g.reload.value).to be true
    expect { cmd(g, "toggle") }.to change { Command.count }.by(3)
    expect([ a.reload.value, b.reload.value, g.reload.value ]).to eq([ false, false, false ])
    cmd(g, "on")
    expect([ a.reload.value, b.reload.value ]).to eq([ true, true ])
    expect(Command.where(point: a).last.source).to eq("web")
    g.update!(address: g.address.merge("mode" => "all"))
    cmd(b, "off")
    expect(g.reload.value).to be false
    expect(Point.usages(site, Point.where(id: a.id)).map(&:first)).to include("Helper")

    a.update!(disabled: true)
    expect(cmd(g, "on")).to have_attributes(status: "failed", error: /#{a.name}: Ponto desativado/)

    bad = described_class.build(site, HelperTypes::Group)
    expect(described_class.save(bad, "name" => "z", "members" => [ a.id ])).to be false
    m = create(:point, device: dev, capability: "measure")
    expect(described_class.save(bad, "name" => "z", "members" => [ a.id, m.id ])).to be false
    expect(described_class.save(bad, "name" => "z", "members" => [ g.id, a.id ])).to be false
  end

  it "grupo de números: média/mín./máx./soma, só leitura; e com membro sem leitura" do
    dev = create(:device, site: site)
    t1 = create(:point, device: dev, capability: "measure", unit: "°C", value: 20)
    t2 = create(:point, device: dev, capability: "measure", unit: "°C", value: 25)
    g = helper("group", "members" => [ t1.id, t2.id ], "mode" => "mean")
    expect(g).to have_attributes(capability: "measure", writable: false, unit: "°C", value: 22.5)
    t2.report!(30)
    expect(g.reload.value).to eq(25.0)
    expect(Points::Command.commands_for(g)).to eq([])
    { "min" => 20, "max" => 30, "sum" => 50 }.each do |mode, v|
      g.update!(address: g.address.merge("mode" => mode))
      HelperTypes::Group.refresh!(g)
      expect(g.reload.value).to eq(v)
    end
    [ t1, t2 ].each { |p| p.report!(p.value, quality: "unavailable") }
    HelperTypes::Group.refresh!(g)
    expect(g.reload.quality).to eq("unavailable")
  end

  it "sensor calculado: número, sim/não e texto, refeito quando a origem muda; erro vira qualidade" do
    dev = create(:device, site: site, name: "Sala")
    temp = create(:point, device: dev, name: "Temperatura", capability: "measure", value: 30)
    ext = create(:point, device: dev, name: "Externa", capability: "measure", value: 25)
    n = helper("template", "kind" => "number", "expr" => "sala.temperatura - sala.externa", "unit" => "°C")
    expect(n).to have_attributes(capability: "measure", writable: false, value: 5)
    expect(n.address["sources"]).to contain_exactly(temp.id, ext.id)
    ext.report!(20)
    expect(n.reload.value).to eq(10)
    b = helper("template", "kind" => "bool", "expr" => "sala.temperatura > 28")
    expect(b).to have_attributes(capability: "onoff", writable: false, value: true)
    s = helper("template", "kind" => "text", "expr" => "Sala a {{ points[\"sala.temperatura\"].value }} graus")
    expect(s.value).to eq("Sala a 30 graus")
    temp.report!(nil)
    expect(n.reload.quality).to eq("error")
    expect(described_class.save(described_class.build(site, HelperTypes::Template), "name" => "x", "expr" => "1 +* (")).to be false
    expect(described_class.save(described_class.build(site, HelperTypes::Template), "name" => "x", "kind" => "text", "expr" => "{% if %}")).to be false
    expect(described_class.save(described_class.build(site, HelperTypes::Template), "name" => "x", "expr" => "")).to be false
  end

  it "estatística: função sobre as leituras da janela" do
    dev = create(:device, site: site)
    src = create(:point, device: dev, capability: "measure")
    travel_to(30.minutes.ago) { src.report!(10) }
    st = helper("statistics", "source" => src.id, "func" => "max", "window" => "1h")
    expect(st.value).to eq(10.0)
    src.report!(40)
    expect(st.reload.value).to eq(40.0)
    st.update!(address: st.address.merge("func" => "mean"))
    src.report!(20)
    expect(st.reload.value).to eq(23.333)
    expect(HelperTypes::Statistics.summary(st)).to include("1 h")
    bad = described_class.build(site, HelperTypes::Statistics)
    expect(described_class.save(bad, "name" => "x", "source" => src.id, "window" => "10s")).to be false
    expect(described_class.save(bad, "name" => "x", "source" => "")).to be false
  end

  it "reinício: quem não restaura volta ao inicial; o temporizador é cancelado" do
    keep = helper("counter", "initial" => "1")
    drop = helper("counter", "initial" => "1", "restore" => "0")
    timer = helper("timer", "duration" => "5m", "restore" => "0")
    [ keep, drop ].each { |c| cmd(c, "increment") }
    cmd(timer, "start")
    described_class.boot!
    expect([ keep.reload.value, drop.reload.value, timer.reload.value ]).to eq([ 2, 1, "idle" ])
  end

  it "escrita de fora valida pelo plugin (check)" do
    c = helper("counter")
    expect(HelperTypes::Counter.check(c, 7)).to eq(7)
    t = helper("template", "expr" => "1 + 1")
    expect(HelperTypes::Template.check(t, 3)).to eq(3)
  end
end
