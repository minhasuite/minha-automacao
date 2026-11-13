require "rails_helper"

# Notificações com menos ruído (docs/push.md, "Menos ruído"): juntar avisos
# seguidos, horário de silêncio por pessoa e da casa, nível crítico que fura,
# silenciar a origem por X horas (também pelo botão do push), resumo diário e
# os filtros da central. Nada sai para fora: transporte e canal falsos.
RSpec.describe "Notificações com menos ruído" do
  let(:tenant) { create(:tenant) }
  let(:owner) { create(:user, tenant: tenant, role: "owner", name: "Dona") }
  let(:site) { within(tenant) { create(:site, name: "Casa", timezone: "America/Sao_Paulo") } }
  let(:area) { within(tenant) { Area.create!(site: site, name: "Garagem") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Virtual", driver: "virtual") } }
  let(:gate) { within(tenant) { create(:point, device: device, site: site, key: "garagem.portao", name: "Portão", capability: "contact", data_type: "bool", value: false, area: area) } }
  let(:pushed) { [] }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  before do
    got = pushed
    fake = Module.new do
      define_singleton_method(:configured?) { true }
      define_singleton_method(:capabilities) { Notifier::FEATURES }
      define_singleton_method(:deliver) { |user, message| got << [ user.id, message.to_h ] }
      define_singleton_method(:clear) { |_user, _tag| nil }
    end
    stub_const("Push::Pombo", fake)
    stub_const("Push::TRANSPORTS", %w[Pombo])
    allow(FeatureFlag).to receive(:on?).and_call_original
    allow(FeatureFlag).to receive(:on?).with("push").and_return(true)
    owner
  end

  def notify(title, at: Time.current, **data)
    travel_to(at) do
      perform_enqueued_jobs(only: SendPushJob) do
        Notifier.deliver!(%w[in_app push], kind: "aviso", title: title, data: { "point_id" => gate.id, "site_id" => site.id }.merge(data.stringify_keys))
      end
    end
  end

  def zone_time(hhmm) = ActiveSupport::TimeZone["America/Sao_Paulo"].parse("2026-11-12 #{hhmm}")

  describe "juntar avisos seguidos" do
    let(:merge) { { merge_key: "point:#{gate.id}", merge_s: 120, merge_subject: "Portão" } }

    it "abriu e fechou em 2 min vira um aviso só, atualizado no lugar e com a mesma tag no push" do
      first = notify("Portão: Aberto", at: zone_time("19:15"), **merge)
      second = notify("Portão: Fechado", at: zone_time("19:17"), **merge)
      expect(second.id).to eq(first.id)
      expect(Notification.count).to eq(1)
      expect(second.reload.title).to eq("Portão")
      expect(second.body).to eq("Aberto às 19:15 e Fechado às 19:17")
      expect(second.count).to eq(2)
      tags = pushed.map { |_, m| m["tag"] }
      expect(tags.uniq).to eq([ "grupo:point:#{gate.id}" ])
      expect(pushed.last.last["renotify"]).to be_nil # atualiza sem tocar de novo
      expect(pushed.last.last.dig("data", "count")).to eq(2)
    end

    it "fora da janela, crítico ou com botões não junta" do
      notify("Portão: Aberto", at: zone_time("19:15"), **merge)
      notify("Portão: Fechado", at: zone_time("19:25"), **merge)
      notify("Portão: Aberto", at: zone_time("19:26"), **merge, priority: "critical")
      notify("Portão: Aberto", at: zone_time("19:26"), **merge, actions: [ { "id" => "ok", "title" => "Ok" } ])
      expect(Notification.count).to eq(4)
    end

    it "texto com hora não ganha outra e a regra de aviso usa a janela da instalação" do
      expect(Notifications::Merge.summary([ { "title" => "Portão aberto às 19:15", "at" => zone_time("19:15").iso8601 } ], "Portão", site.timezone)).to eq("Aberto às 19:15")
      Notifications.save_house!(tenant, Notifications.house_prefs(tenant).merge("merge_s" => 300))
      rule = NotifyRule.create!(point: gate, channels: %w[in_app], priority: "high")
      travel_to(zone_time("08:00")) { rule.deliver(gate) }
      travel_to(zone_time("08:04")) { rule.deliver(gate) }
      n = Notification.sole
      expect([ n.data["merge_s"], n.level, n.count ]).to eq([ 300, "high", 2 ])
      rule.update!(merge_s: 0)
      travel_to(zone_time("08:05")) { rule.deliver(gate) }
      expect(Notification.count).to eq(2)
    end

    it "a ação Avisar junta pela automação (ou pela tag) com a janela do bloco" do
      a = Automation.create!(site: site, name: "Portão avisa", kind: "automation")
      a.publish!({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "notify", "channels" => [ "in_app" ], "title" => "Mexeu", "merge" => "2m" } ] })
      a.update!(enabled: true)
      2.times { a.fire!({ "type" => "manual" }) }
      n = Notification.sole
      expect(n.data).to include("merge_key" => "automation:#{a.id}", "merge_s" => 120, "merge_subject" => "Portão avisa")
      expect(n.mute_key).to eq("automation:#{a.id}")
      a.publish!({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "notify", "channels" => [ "in_app" ], "title" => "Outro" } ] })
      2.times { a.fire!({ "type" => "manual" }) }
      expect(Notification.where(title: "Outro").count).to eq(2) # sem `merge` no bloco, não junta
    end
  end

  describe "horário de silêncio" do
    before { Notifications.save_user!(owner, Notifications.user_prefs(owner).merge("quiet" => { "enabled" => true, "from" => "22:00", "to" => "07:00" })) }

    it "segura o push da pessoa e deixa o aviso no app; crítico fura" do
      n = notify("Portão: Aberto", at: zone_time("23:30"))
      expect(n).to be_persisted
      expect(pushed).to be_empty
      notify("Vazamento", at: zone_time("23:31"), priority: "critical")
      expect(pushed.size).to eq(1)
      notify("Portão: Fechado", at: zone_time("09:00"))
      expect(pushed.size).to eq(2)
    end

    it "passa da meia-noite, de = até é o dia todo e desligado não cala" do
      tz = ActiveSupport::TimeZone["America/Sao_Paulo"]
      w = { "enabled" => true, "from" => "22:00", "to" => "07:00" }
      expect(Notifications.quiet_now?(w, zone_time("06:59"), tz)).to be true
      expect(Notifications.quiet_now?(w, zone_time("07:00"), tz)).to be false
      expect(Notifications.quiet_now?(w.merge("from" => "13:00", "to" => "15:00"), zone_time("14:00"), tz)).to be true
      expect(Notifications.quiet_now?(w.merge("to" => "22:00"), zone_time("12:00"), tz)).to be true
      expect(Notifications.quiet_now?(w.merge("enabled" => false), zone_time("23:00"), tz)).to be false
      expect(Notifications.quiet_now?(w.merge("from" => "25:00"), zone_time("23:00"), tz)).to be false
    end

    it "o silêncio da casa cala os canais da casa (fala), nunca o app, e crítico fura" do
      spoken = []
      fake = Module.new do
        define_singleton_method(:owns?) { |c| c.start_with?("eco:") }
        define_singleton_method(:choices) { |_site| [] }
        define_singleton_method(:label) { |_c| "Eco" }
        define_singleton_method(:capabilities) { %i[text] }
        define_singleton_method(:quiet_scope) { :house }
        define_singleton_method(:deliver) { |_c, list| spoken << list.first.title }
      end
      stub_const("Notifier::Channels::Eco", fake)
      stub_const("Notifier::CHANNELS", Notifier::CHANNELS + %w[Eco])
      Notifications.save_house!(tenant, Notifications.house_prefs(tenant).merge("quiet" => { "enabled" => true, "from" => "22:00", "to" => "07:00" }))
      travel_to(zone_time("23:00")) do
        Notifier.deliver!(%w[in_app eco:1], kind: "aviso", title: "Normal", data: { "site_id" => site.id })
        Notifier.deliver!(%w[in_app eco:1], kind: "alerta", title: "Alarme", data: { "site_id" => site.id, "priority" => "critical" })
      end
      expect(spoken).to eq([ "Alarme" ])
      expect(Notification.count).to eq(2)
      expect(Notifier::Channels::Alexa.quiet_scope).to eq(:house)
      expect(Notifier::Channels::Push.quiet_scope).to eq(:person)
    end

    it "o alerta leva o nível pela gravidade e a tag dele" do
      rule = AlertRule.create!(site: site, point: gate, name: "Portão aberto há muito", operator: "eq", value: true, severity: "critical",
                               escalation: [ { "wait_s" => 0, "channels" => %w[in_app push] } ])
      alert = Alert.create!(site: site, alert_rule: rule, point: gate, opened_at: Time.current)
      travel_to(zone_time("23:40")) { perform_enqueued_jobs(only: SendPushJob) { alert.notify_step!(rule.escalation.first, 0) } }
      expect(Notification.last.data).to include("priority" => "critical", "tag" => "alerta:#{alert.id}")
      expect(pushed.size).to eq(1) # crítico fura o silêncio
    end
  end

  describe "silenciar por X horas" do
    it "silencia a origem para a pessoa, some com o tempo e o crítico ainda chega" do
      n = notify("Portão: Aberto")
      expect(pushed.size).to eq(1)
      until_at = n.mute!(owner, 2)
      expect(until_at).to be_within(5.seconds).of(2.hours.from_now)
      expect(Notifications.mute_list(owner).sole).to include("key" => "point:#{gate.id}", "label" => "Portão")
      notify("Portão: Fechado")
      expect(pushed.size).to eq(1)
      notify("Portão: Arrombado", priority: "critical")
      expect(pushed.size).to eq(2)
      travel_to(3.hours.from_now) do
        expect(Notifications.muted?(owner, "point:#{gate.id}")).to be false
      end
      Notifications.unmute!(owner, "point:#{gate.id}")
      expect(Notifications.mute_list(owner)).to be_empty
    end

    it "o push leva o botão Silenciar quando há espaço e o toque silencia sem responder ao aviso" do
      n = notify("Portão: Aberto")
      msg = pushed.sole.last
      expect(msg["actions"]).to eq([ { "action" => Notification::MUTE_ACTION, "title" => "Silenciar 1 h" } ])
      token = msg.dig("data", "token")
      expect(token).to be_present
      with = Push::Message.new(Notification.new(tenant: tenant, kind: "aviso", title: "x", data: { "point_id" => gate.id, "priority" => "critical" }), owner)
      expect(with.mute_button).to eq([])
      expect(Push::Message.new(Notification.new(tenant: tenant, kind: "sistema", title: "x", data: {}), owner).mute_button).to eq([])

      ActsAsTenant.without_tenant do
        ActionDispatch::Integration::Session.new(Rails.application).tap do |s|
          s.host! "www.example.com"
          s.post "/push/resposta", params: { token: token, action_id: Notification::MUTE_ACTION }, as: :json
          expect(s.response.status).to eq(204)
        end
      end
      expect(n.reload.responded_at).to be_nil
      expect(Notifications.muted?(owner.reload, "point:#{gate.id}")).to be true
    end

    it "aviso sem origem não tem o que silenciar" do
      n = Notifier.notify!(kind: "sistema", title: "Atualização", push: false)
      expect(n.mute_key).to be_nil
      expect(n.mute!(owner)).to be_nil
      expect { Notifications.mute!(owner, "", 1) }.to raise_error(ArgumentError)
    end
  end

  describe "resumo diário" do
    before do
      NotifyRule.create!(point: gate, channels: %w[in_app])
      Reading.insert_all!([ { point_id: gate.id, at: 2.hours.ago, value: 1 }, { point_id: gate.id, at: 1.hour.ago, value: 1 },
                            { point_id: gate.id, at: 90.minutes.ago, value: 0 } ])
      battery = within(tenant) { create(:point, device: device, site: site, key: "virtual.bateria", name: "Bateria", capability: "measure", data_type: "decimal", value: 12) }
      device.update!(battery_point_id: battery.id)
      rule = AlertRule.create!(site: site, point: gate, name: "Vazamento", operator: "eq", value: true, severity: "critical", escalation: [])
      Alert.create!(site: site, alert_rule: rule, point: gate, opened_at: 3.hours.ago)
      Command.create!(site: site, point: gate, command: "on", status: "failed", source: "automation")
      Notifier.notify!(kind: "aviso", title: "Oi", push: false)
    end

    it "monta as partes do que aconteceu" do
      parts = Notifications::Digest.build(owner).to_h { |p| [ p["key"], p["lines"] ] }
      expect(parts["openings"]).to eq([ "Portão: Aberto 2 vezes" ])
      expect(parts["alerts"]).to eq([ "1 alerta: Vazamento" ])
      expect(parts["failures"]).to eq([ "1 comando com falha: Portão" ])
      expect(parts["battery"]).to eq([ "Bateria baixa: Virtual (12%)" ])
      expect(parts["notices"]).to eq([ "1 aviso" ])
    end

    it "manda um push só por dia na hora escolhida" do
      Notifications.save_user!(owner, Notifications.user_prefs(owner).merge("digest" => { "enabled" => true, "at" => "08:00" }))
      travel_to(zone_time("07:59")) { Notifications::Digest.tick }
      expect(Notification.where(kind: "resumo_diario")).to be_empty
      travel_to(zone_time("08:00")) { perform_enqueued_jobs(only: SendPushJob) { Notifications::Digest.tick } }
      travel_to(zone_time("08:01")) { Notifications::Digest.tick }
      d = Notification.where(kind: "resumo_diario").sole
      expect(d.user_id).to eq(owner.id)
      expect(d.data["url"]).to eq("/notificacoes/resumo")
      expect(pushed.map { |_, m| m["title"] }).to eq([ "Resumo do dia" ])
    end
  end

  describe "filtros e preferências" do
    it "filtra por tipo, área, nível e não lidas" do
      notify("Portão: Aberto", priority: "high")
      Notifier.notify!(kind: "sistema", title: "Atualização", push: false)
      base = Notification.for_user(owner)
      expect(Notifications::Filter.apply(base, { kind: "sistema" }).pluck(:title)).to eq([ "Atualização" ])
      expect(Notifications::Filter.apply(base, { area_id: area.id }).pluck(:title)).to eq([ "Portão: Aberto" ])
      expect(Notifications::Filter.apply(base, { level: "high" }).count).to eq(1)
      expect(Notifications::Filter.apply(base, { level: "normal" }).pluck(:title)).to eq([ "Atualização" ])
      expect(Notifications::Filter.apply(base, { unread: "1", kind: "nada" }).count).to eq(2)
      choices = Notifications::Filter.choices(owner)
      expect(choices[:kinds].map(&:first)).to contain_exactly("sistema", "aviso")
      expect(choices[:areas]).to eq([ [ area.id, "Garagem" ] ])
    end

    it "grava as da pessoa e, de administrador, as da casa; valor ruim volta ao anterior" do
      Notifications::Settings.update(owner, { quiet_enabled: "1", quiet_from: "23:00", quiet_to: "99:00", digest_enabled: "1", digest_at: "07:30",
                                              mute_hours: "4", house_quiet_enabled: "1", house_quiet_from: "22:30", house_quiet_to: "06:00", merge_s: "300" })
      shown = Notifications::Settings.show(owner.reload)
      expect(shown["quiet"]).to eq("enabled" => true, "from" => "23:00", "to" => "07:00")
      expect(shown["digest"]).to eq("enabled" => true, "at" => "07:30")
      expect(shown["mute_hours"]).to eq(4)
      expect(shown["house"]).to eq("quiet" => { "enabled" => true, "from" => "22:30", "to" => "06:00" }, "merge_s" => 300)
      member = create(:user, tenant: tenant, role: "member")
      Notifications::Settings.update(member, { house_quiet_enabled: "0", merge_s: "0" })
      expect(Notifications.merge_window(tenant.reload)).to eq(300)
      expect(Notifications::Settings.show(member)).not_to have_key("house")
    end
  end
end
