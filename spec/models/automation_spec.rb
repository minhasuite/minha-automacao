require "rails_helper"

# Primitivas da F4 contra os casos reais do HA da casa (Issues do repo HomeAssistant).
RSpec.describe "Automação: primitivas declarativas" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, latitude: -15.79, longitude: -47.88) }
  let(:device) { create(:device, site: site) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def point(**attrs) = create(:point, device: device, site: site, **attrs)
  def cmd(p, command, value = nil) = Points::Command.call(p, command, value, source: "web", user: nil)
  # Avança o relógio e roda os jobs que venceram (como o Solid Queue faria).
  def pass(duration)
    travel(duration)
    perform_enqueued_jobs(at: Time.current)
  end

  describe "pulse_ms e max_on_s" do
    it "portão: liga e desliga sozinho depois do pulso" do
      relay = point(name: "Portão garagem", pulse_ms: 3000)
      cmd(relay, "on")
      expect(relay.reload.value).to be true
      pass(2.seconds)
      expect(relay.reload.value).to be true
      pass(2.seconds)
      expect(relay.reload.value).to be false
      expect(relay.commands.recent.first).to have_attributes(command: "off", source: "automation")
    end

    it "filtro da piscina: desliga em 4h; religar recomeça a conta e o job velho não age" do
      filter = point(name: "Filtro", max_on_s: 4.hours.to_i)
      cmd(filter, "on")
      pass(3.hours)
      cmd(filter, "off")
      cmd(filter, "on") # religou: conta de novo
      pass(1.hour + 1.second)
      expect(filter.reload.value).to be true
      pass(3.hours)
      expect(filter.reload.value).to be false
    end

    it "vale para ligado por fora (aparelho físico) e sobrevive a reinício (só o banco guarda o prazo)" do
      filter = point(name: "Filtro", max_on_s: 60)
      filter.report!(true) # botão físico, relatado pelo driver
      job = enqueued_jobs.find { |j| j["job_class"] == "AutoOffJob" }
      expect(job["scheduled_at"]).to be_present
      Point.find(filter.id) # nada em memória: o job só tem id e carimbo
      pass(61.seconds)
      expect(filter.reload.value).to be false
    end
  end

  describe "PointLink" do
    it "espelha escada ↔ terraço nos dois sentidos sem laço" do
      terraco = point(name: "Interruptor terraço")
      escada = point(name: "Luz escada")
      PointLink.create!(source_point: terraco, target_point: escada, bidirectional: true)
      cmd(terraco, "on")
      expect(escada.reload.value).to be true
      cmd(escada, "off")
      expect(terraco.reload.value).to be false
      expect(Command.where(point: [ terraco, escada ]).count).to eq(4) # 2 pedidos + 2 espelhos, sem eco
    end

    it "inverte e não comanda destino que já está no valor" do
      a = point
      b = point(value: true)
      PointLink.create!(source_point: a, target_point: b, mode: "invert")
      cmd(a, "on")
      expect(b.reload.value).to be false
      expect(b.commands.count).to eq(1)
      cmd(a, "off")
      expect(b.reload.value).to be true
    end

    it "interruptor aciona o relé do portão, que pulsa sozinho" do
      switch = point(name: "Interruptor portão")
      relay = point(name: "Relé portão", pulse_ms: 1000)
      PointLink.create!(source_point: switch, target_point: relay, mode: "trigger")
      cmd(switch, "on")
      expect(relay.reload.value).to be true
      pass(2.seconds)
      expect(relay.reload.value).to be false
      cmd(switch, "off") # trigger só no valor escolhido (ligado)
      expect(relay.reload.value).to be false
      gate = point(capability: "gate")
      PointLink.create!(source_point: switch, target_point: gate, mode: "trigger")
      cmd(switch, "on")
      expect(gate.reload.value).to eq("open")
    end

    it "recusa laço com outros espelhamentos, ponto de outro local e combinação sem sentido" do
      a, b, c = point, point, point
      PointLink.create!(source_point: a, target_point: b)
      PointLink.create!(source_point: b, target_point: c)
      expect(PointLink.new(source_point: c, target_point: a)).not_to be_valid
      expect(PointLink.new(source_point: a, target_point: a)).not_to be_valid
      sensor = point(capability: "contact")
      expect(PointLink.new(source_point: c, target_point: sensor)).not_to be_valid
      expect(PointLink.new(source_point: sensor, target_point: c, bidirectional: true)).not_to be_valid
      expect(PointLink.new(source_point: sensor, target_point: c)).to be_valid
      other = create(:point)
      expect(PointLink.new(source_point: c, target_point: other)).not_to be_valid
    end

    it "corrente síncrona longa para no limite" do
      points = Array.new(8) { point }
      points.each_cons(2) { |x, y| PointLink.create!(source_point: x, target_point: y) }
      cmd(points.first, "on")
      expect(points.map { |p| p.reload.value }.count(true)).to eq(Automations::MAX_DEPTH + 1)
    end

    it "não volta o eco do próprio comando (aparelho real responde depois)" do
      a = point
      b = point
      link = PointLink.create!(source_point: a, target_point: b, bidirectional: true)
      a.update!(value: true)
      Command.create!(site: site, point: b, command: "on", source: "automation", origin_point_id: a.id, status: "confirmed")
      b.update!(value: true)
      expect(Points::Command).not_to receive(:call)
      link.forward(b, a)
    end

    it "valor que volta com a conexão (estava indisponível) não aciona nada" do
      a = point(quality: "unavailable")
      b = point
      PointLink.create!(source_point: a, target_point: b)
      a.report!(true)
      expect(b.reload.value).to be_nil
    end
  end

  describe "Schedule e Sun" do
    it "calcula nascer e pôr do sol em Brasília" do
      zone = ActiveSupport::TimeZone["America/Sao_Paulo"]
      date = Date.new(2026, 10, 29)
      rise = Sun.at("sunrise", date, -15.79, -47.88, zone).in_time_zone(zone)
      set = Sun.at("sunset", date, -15.79, -47.88, zone).in_time_zone(zone)
      expect(rise.strftime("%H:%M")).to be_between("05:30", "05:42") # meio-dia solar 11:55, dia de 12h37
      expect(set.strftime("%H:%M")).to be_between("18:08", "18:20")
      expect(Sun.at("sunrise", Date.new(2026, 6, 21), 80, 0, "UTC")).to be_nil # sol da meia-noite
    end

    it "liga a sala às 17h nos dias marcados e pula o que perdeu com o servidor fora" do
      sala = point(name: "Sala")
      travel_to(Time.zone.parse("2026-10-29 10:00")) # quinta
      s = Schedule.create!(name: "Ligar sala", point: sala, command: "on", time_of_day: "17:00", days: [ 4, 5 ])
      expect(s.next_run_at).to eq(Time.zone.parse("2026-10-29 17:00"))
      travel_to(Time.zone.parse("2026-10-29 17:00:30"))
      Schedule.run_due
      expect(sala.reload.value).to be true
      expect(s.reload.next_run_at).to eq(Time.zone.parse("2026-10-30 17:00"))
      cmd(sala, "off")
      travel_to(Time.zone.parse("2026-10-30 21:00")) # servidor voltou 4h depois
      RunSchedulesJob.perform_now
      expect(sala.reload.value).to be false
      expect(s.reload.next_run_at).to eq(Time.zone.parse("2026-11-05 17:00"))
    end

    it "pôr do sol com atraso, aciona cena e valida o alvo" do
      luz = point
      scene = Scene.create!(site: site, name: "Fim de tarde", items: [ { point_id: luz.id, command: "on" } ])
      travel_to(Time.zone.parse("2026-10-29 10:00"))
      s = Schedule.create!(name: "Fim de tarde", scene: scene, kind: "sunset", offset_min: 15)
      expect(s.next_run_at.in_time_zone("America/Sao_Paulo").hour).to eq(18)
      expect(s.when_label).to eq("pôr do sol + 15 min, todos os dias")
      travel_to(s.next_run_at + 10.seconds)
      Schedule.run_due
      expect(luz.reload.value).to be true
      expect(Schedule.new(name: "x", point: luz, scene: scene)).not_to be_valid
      expect(Schedule.new(name: "x", point: luz, command: "press", time_of_day: "17:00")).not_to be_valid
      expect(Schedule.new(name: "x", point: luz, command: "on", time_of_day: "25:00")).not_to be_valid
      expect(Schedule.new(name: "x", point: luz, command: "on", time_of_day: "17:00", days: [])).not_to be_valid
      nowhere = create(:site)
      far = create(:point, device: create(:device, site: nowhere), site: nowhere)
      expect(Schedule.new(name: "x", point: far, command: "on", kind: "sunrise")).not_to be_valid
    end
  end

  describe "Scene" do
    it "aciona tudo, segue com erro num ponto e calcula o risco" do
      a = point
      b = point(capability: "dimmer")
      gate = point(capability: "gate", risk: "sensitive")
      scene = Scene.create!(site: site, name: "Chegada", items: [
        { point_id: a.id, command: "on" }, { point_id: b.id, command: "set", value: "500" }, { point_id: gate.id, command: "pulse" }
      ])
      commands, failures = scene.activate!(source: "web")
      expect(commands.size).to eq(2)
      expect(failures.first).to include(b.name)
      expect(a.reload.value).to be true
      expect(scene.risk).to eq("sensitive")
      expect(Scene.new(site: site, name: "x", items: [])).not_to be_valid
      expect(Scene.new(site: site, name: "x", items: [ { point_id: a.id, command: "pulse" } ])).not_to be_valid
    end
  end

  describe "NotifyRule" do
    it "avisa o portão aberto e, sem valor, toda mudança (seguidas da mesma regra viram um aviso só)" do
      gate = point(capability: "contact", name: "Portão")
      NotifyRule.create!(point: gate, to_value: "true", message: "{ponto} ficou {valor}")
      every = NotifyRule.create!(point: gate, channels: %w[in_app])
      gate.report!(true)
      gate.report!(false)
      expect(Notification.pluck(:kind, :title)).to contain_exactly([ "aviso", "Portão ficou Aberto" ], [ "aviso", "Portão" ])
      expect(Notification.find_by(title: "Portão").body).to match(/\AAberto às \d\d:\d\d e Fechado às \d\d:\d\d\z/)
      every.update!(merge_s: 0)
      gate.report!(true)
      expect(Notification.where(title: "Portão: Aberto").count).to eq(1)
      expect(NotifyRule.new(point: gate, channels: %w[alexa])).not_to be_valid
    end
  end

  describe "AlertRule e Alert" do
    let(:door) { point(capability: "contact", name: "Porta de vidro 1", value: false) }
    let(:rule) do
      AlertRule.create!(point: door, name: "Porta de vidro aberta", value: "true", for_s: 300, repeat_s: 600,
                        steps: { "0" => { wait_min: "0", channels: %w[in_app] }, "1" => { wait_min: "5", channels: %w[in_app push] } })
    end

    def titles = Notification.where(kind: "alerta").count

    it "abre depois de 5 min aberta, escala, repete e para no ciente" do
      rule
      travel_to(Time.zone.parse("2026-10-29 10:00"))
      door.report!(true)
      pass(4.minutes)
      expect(Alert.count).to eq(0)
      pass(1.minute + 1.second)
      alert = Alert.active.sole
      expect(titles).to eq(1)
      pass(5.minutes)
      expect(titles).to eq(2)
      expect(Notification.where(kind: "alerta").order(:created_at).last.body).to include("há 10 min")
      pass(10.minutes) # repetição
      expect(titles).to eq(3)
      alert.ack!(create(:user, tenant: tenant))
      pass(1.hour)
      expect(titles).to eq(3)
      expect(alert.reload.resolved_at).to be_nil # ciente não fecha enquanto está aberta
      door.report!(false)
      expect(alert.reload.resolved_at).to be_present
    end

    it "fechou antes do prazo: não abre; fechou depois: resolve sozinho; reabre: novo alerta" do
      rule
      door.report!(true)
      pass(2.minutes)
      door.report!(false)
      pass(10.minutes)
      expect(Alert.count).to eq(0)
      door.report!(true)
      pass(6.minutes)
      door.report!(false)
      expect(Alert.sole.resolved_at).to be_present
      door.report!(true)
      pass(6.minutes)
      expect(Alert.active.count).to eq(1)
    end

    it "regra criada com a condição já valendo abre na hora; desativar resolve; sem auto_resolve fecha no ciente" do
      door.update!(value: true, changed_at: 1.hour.ago)
      rule
      expect(Alert.active.count).to eq(1)
      rule.update!(enabled: false)
      expect(Alert.active.count).to eq(0)
      temp = point(capability: "measure", name: "Temperatura", value: 40)
      hot = AlertRule.create!(point: temp, name: "Quente", operator: "gt", value: "35,5", auto_resolve: false)
      expect(hot.value).to eq(35.5)
      alert = Alert.active.sole
      temp.report!(20)
      expect(alert.reload.resolved_at).to be_nil
      alert.ack!(nil)
      expect(alert.reload.resolved_at).to be_present
      expect(AlertRule.new(point: temp, name: "x", operator: "gt", value: "abc")).not_to be_valid
      expect(AlertRule.new(point: temp, name: "x", escalation: [ { "wait_s" => -1, "channels" => [ "in_app" ] } ])).not_to be_valid
    end

    it "job repetido não avisa duas vezes" do
      door.update!(value: true, changed_at: 1.hour.ago)
      rule
      alert = Alert.active.sole
      AlertStepJob.perform_now(alert.id, 0)
      AlertCheckJob.perform_now(rule.id, "outro carimbo")
      expect(titles).to eq(1)
    end
  end
end
