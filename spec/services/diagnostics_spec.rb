require "rails_helper"

# Saúde dos aparelhos (docs/saude-aparelhos.md): regras como plugins, limiares
# por dado, silenciar, ajustes do local, reparos seguros e aviso de bateria.
RSpec.describe "Saúde dos aparelhos: diagnóstico (Diagnostics)" do
  let(:tenant) { create(:tenant) }
  let!(:site) { within(tenant) { create(:site, name: "Teste Casa") } }
  let!(:sala) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let(:now) { Time.current }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def run = Diagnostics.run(site, now: now)
  def keys(list = run) = list.map { |f| [ f.rule.key, f.name ] }

  def dev(name, **attrs)
    d = create(:device, site: site, area: sala, name: name, driver: "virtual", status: "online", last_seen_at: now, **attrs)
    create(:point, device: d, site: site, name: "#{name} estado", capability: "onoff")
    d
  end

  def tuya_integration(found)
    Integration.create!(site: site, driver: "tuya", name: "Teste Tuya", status: "ok", inventory: found.to_json)
  end

  it "não acha nada num local saudável" do
    dev("Teste Luz")
    expect(run).to be_empty
  end

  it "todas as regras e reparos estão registrados, com textos nos três idiomas" do
    expect(Diagnostics.rules.map(&:key).uniq.size).to eq(Diagnostics::RULES.size)
    expect(Diagnostics.fixes.map(&:key).uniq.size).to eq(Diagnostics::FIXES.size)
    (Diagnostics.rules + Diagnostics.fixes).each do |k|
      %w[en es].each { |loc| expect(k.texts[loc].keys).to include("label", *k.source_texts.keys), "#{k} #{loc}" }
    end
  end

  describe "sem sinal" do
    it "acha o aparelho sem sinal com o motivo pelo tipo de endereço e vira erro depois de dias" do
      dev("Teste Tomada", status: "offline", last_seen_at: 3.hours.ago, address: { "host" => "192.168.0.50" })
      dev("Teste Queimado", status: "offline", last_seen_at: 5.days.ago)
      dev("Teste Recente", status: "offline", last_seen_at: 10.minutes.ago)
      f = run.select { |x| x.rule.key == "offline" }.index_by(&:name)
      expect(f.keys).to contain_exactly("Teste Tomada", "Teste Queimado")
      expect(f["Teste Tomada"]).to have_attributes(severity: "warn")
      expect(f["Teste Tomada"].reason).to include("DHCP")
      expect(f["Teste Queimado"]).to have_attributes(severity: "error")
      expect(f["Teste Queimado"].reason).to include("queimado")
      expect(f["Teste Queimado"].fixes).to include("edit", "replace", "delete_device")
    end

    it "respeita as horas do local" do
      dev("Teste Tomada", status: "offline", last_seen_at: 3.hours.ago)
      Diagnostics.update_settings!(site, { "offline_hours" => "6" })
      expect(run).to be_empty
    end

    it "hub fora: um achado no hub e os filhos não repetem" do
      hub = dev("Teste Hub", status: "offline", last_seen_at: 2.hours.ago, external_id: "hub1")
      dev("Teste Sensor porta", status: "offline", last_seen_at: 2.hours.ago, address: { "via" => "hub1" })
      expect(keys).to contain_exactly([ "hub_down", hub.name ])
      expect(run.first.detail).to include("Teste Sensor porta")
    end

    it "integração fora com vários aparelhos caídos: um achado na integração" do
      i = Integration.create!(site: site, driver: "mqtt", name: "Teste Z2M", status: "error", last_error: "coordenador fora")
      2.times { |n| dev("Teste Zigbee #{n}", status: "offline", last_seen_at: 2.hours.ago, integration: i) }
      expect(keys).to contain_exactly([ "integration_down", "Teste Z2M" ])
      expect(run.first.detail).to include("2", "coordenador fora")
    end
  end

  describe "IP mudou" do
    it "acha pelo inventário da conta e o reparo grava o IP com AuditEvent" do
      i = tuya_integration([ { "id" => "abc", "address" => { "host" => "192.168.0.77" } } ])
      d = dev("Teste Lâmpada", driver: "tuya_local", external_id: "abc", integration: i, address: { "host" => "192.168.0.10", "version" => "3.3" })
      f = run.find { |x| x.rule.key == "ip_changed" }
      expect(f.detail).to include("192.168.0.10", "192.168.0.77")
      expect(f.fixes).to include("apply_ip", "scan")
      msg = Diagnostics.fix("apply_ip").call(f, user: nil)
      expect(msg).to include("192.168.0.77")
      expect(d.reload.address).to include("host" => "192.168.0.77", "version" => "3.3")
      expect(AuditEvent.where(action: "device.ip_update", auditable_id: d.id).last.details).to eq("from" => "192.168.0.10", "to" => "192.168.0.77")
      expect(run.map { |x| x.rule.key }).not_to include("ip_changed")
    end
  end

  describe "cadastro" do
    it "removido da conta, sem pontos (depois da carência), duplicado e sem área" do
      gone = dev("Teste Sumiu", removed_at: 1.day.ago)
      create(:device, site: site, area: sala, name: "Teste Vazio", created_at: 5.hours.ago, status: "online")
      create(:device, site: site, area: sala, name: "Teste Novo", status: "online")
      dev("Teste Original", driver: "tuya_local", external_id: "x1", created_at: 2.days.ago)
      dev("Teste Cópia", driver: "tuya_local", external_id: "x1")
      solto = create(:device, site: site, name: "Teste Solto", status: "online", last_seen_at: now)
      create(:point, device: solto, site: site, name: "Teste Solto estado", capability: "onoff")
      expect(keys).to contain_exactly([ "removed", gone.name ], [ "no_points", "Teste Vazio" ], [ "duplicate", "Teste Cópia" ], [ "no_area", "Teste Solto" ])
      dup = run.find { |x| x.rule.key == "duplicate" }
      expect(dup.detail).to include("Teste Original")
      expect(dup.fixes).to include("replace", "delete_device")
      expect(run.find { |x| x.rule.key == "no_area" }).to have_attributes(severity: "info", fixes: [ "set_area" ])
    end

    it "câmeras do mesmo DVR (mesmo IP, caminhos diferentes) não são duplicadas" do
      2.times { |n| dev("Teste Canal #{n}", driver: "go2rtc", address: { "host" => "192.168.0.115", "path" => "/c#{n}" }) }
      expect(run.map { |x| x.rule.key }).not_to include("duplicate")
    end

    it "câmera sem fonte de vídeo" do
      cam = create(:device, site: site, area: sala, name: "Teste Câmera", driver: "go2rtc", status: "online", address: {})
      create(:point, device: cam, site: site, name: "Ao vivo", capability: "stream", address: { "path" => "/live" })
      ok = create(:device, site: site, area: sala, name: "Teste Câmera boa", driver: "go2rtc", status: "online", address: { "host" => "192.168.0.9" })
      create(:point, device: ok, site: site, name: "Ao vivo", capability: "stream", address: { "path" => "/live" })
      expect(keys).to contain_exactly([ "camera_no_stream", "Teste Câmera" ])
    end

    it "apagar cadastro órfão guarda o que era no AuditEvent" do
      gone = dev("Teste Sumiu", removed_at: 1.day.ago, external_id: "zz")
      f = run.find { |x| x.rule.key == "removed" }
      expect(Diagnostics.fix("delete_device").confirm_text(f)).to include("Teste Sumiu", "1")
      Diagnostics.fix("delete_device").call(f, user: nil)
      expect(Device.exists?(gone.id)).to be(false)
      ev = AuditEvent.find_by(action: "device.orphan_delete", auditable_id: gone.id)
      expect(ev.details).to include("rule" => "removed", "name" => "Teste Sumiu", "external_id" => "zz", "points" => [ a_string_including("teste_sumiu") ])
    end

    it "definir área" do
      solto = create(:device, site: site, name: "Teste Solto", status: "online", last_seen_at: now)
      create(:point, device: solto, site: site, name: "x", capability: "onoff")
      f = run.find { |x| x.rule.key == "no_area" }
      expect(Diagnostics.fix("set_area").options(f, nil)).to eq([ [ "Sala", sala.id ] ])
      expect { Diagnostics.fix("set_area").call(f, user: nil, params: {}) }.to raise_error(Diagnostics::Error)
      Diagnostics.fix("set_area").call(f, user: nil, params: { area_id: sala.id })
      expect(solto.reload.area).to eq(sala)
    end
  end

  describe "leituras suspeitas" do
    let(:sensor) { dev("Teste Vaso") }

    def measure(name, device_class, value, changed: now, unit: "%")
      create(:point, device: sensor, site: site, name: name, capability: "measure", device_class: device_class, unit: unit,
                     value: value, changed_at: changed, reported_at: now)
    end

    it "bateria baixa pelo limiar do local, crítica vira erro" do
      measure("Teste Bateria", "battery", 12)
      expect(run.find { |x| x.rule.key == "battery_low" }).to have_attributes(severity: "warn", detail: "Bateria em 12% (limite 20%)")
      Diagnostics.update_settings!(site, { "battery_low_pct" => "10" })
      expect(run).to be_empty
      Diagnostics.update_settings!(site, { "battery_low_pct" => "30", "battery_critical_pct" => "15" })
      expect(run.first.severity).to eq("error")
    end

    it "umidade do solo 0% por horas = fora da terra; valor parado; ignora quem não tem limiar" do
      measure("Teste Umidade solo", "moisture", 0, changed: 5.hours.ago)
      measure("Teste Temperatura", "temperature", 24.5, changed: 2.days.ago, unit: "°C")
      measure("Teste Potência", "power", 0, changed: 3.days.ago, unit: "W")
      f = run.index_by(&:name)
      expect(f.keys).to contain_exactly("Teste Umidade solo", "Teste Temperatura")
      expect(f["Teste Umidade solo"].rule.key).to eq("zero_reading")
      expect(f["Teste Umidade solo"].reason).to include("fora da terra")
      expect(f["Teste Temperatura"].rule.key).to eq("value_stuck")
      expect(f["Teste Temperatura"].fixes).to eq([]) # virtual não tem leitura
    end

    it "pulo absurdo entre duas leituras seguidas" do
      p = measure("Teste Temperatura", "temperature", 70, unit: "°C")
      Reading.insert_all!([ { point_id: p.id, at: 50.minutes.ago, value: 24 }, { point_id: p.id, at: 40.minutes.ago, value: 70 },
                            { point_id: p.id, at: 3.minutes.ago, value: 71 } ])
      f = run.find { |x| x.rule.key == "value_jump" }
      expect(f.detail).to eq("De 24 para 70°C em 10 min")
    end
  end

  describe "silenciar" do
    it "some da contagem até vencer e grava AuditEvent" do
      dev("Teste Tomada", status: "offline", last_seen_at: 3.hours.ago)
      ref = run.first.ref
      expect { Diagnostics.snooze!(site, ref, 3) }.to raise_error(Diagnostics::Error)
      Diagnostics.snooze!(site, ref, 7)
      expect(run.first).to be_snoozed
      expect(Diagnostics.problems(run)).to be_empty
      expect(AuditEvent.where(action: "device_health.snooze").last.details["ref"]).to eq(ref)
      expect(Diagnostics.run(site, now: 8.days.from_now).first).not_to be_snoozed
      Diagnostics.unsnooze!(site, ref)
      expect(run.first).not_to be_snoozed
    end
  end

  it "regra que quebra não derruba as outras" do
    dev("Teste Tomada", status: "offline", last_seen_at: 3.hours.ago)
    allow(Diagnostics::Rules::NoArea).to receive(:applies?).and_raise("boom")
    expect(keys).to eq([ [ "offline", "Teste Tomada" ] ])
  end

  it "ajustes do local: só as chaves editáveis, no tipo e na faixa" do
    Diagnostics.update_settings!(site, { "battery_low_pct" => "500", "battery_notify" => "0", "other" => "1", "offline_hours" => "x" })
    s = Diagnostics.settings(site)
    expect(s).to include("battery_low_pct" => 90, "battery_notify" => false, "offline_hours" => 1)
    expect(site.reload.settings["device_health"]["values"].keys).to contain_exactly("battery_low_pct", "battery_notify")
  end

  describe "Saúde e aviso" do
    it "entra na Saúde como verificação, com a contagem e o link" do
      dev("Teste Tomada", status: "offline", last_seen_at: 3.hours.ago)
      r = Health.run(tenant, only: "device_health").first
      expect(r.items.first).to have_attributes(status: "warn", detail: a_string_including("1 problema(s)"))
      expect(r.items.first.fix[:url]).to eq("/saude-aparelhos?site_id=#{site.id}")
      expect(Health.check("device_health").alerts?).to be(false)
    end

    it "avisa bateria baixa uma vez por semana e respeita o desligado" do
      p = create(:point, device: dev("Teste Sensor"), site: site, name: "Teste Bateria", capability: "measure", device_class: "battery", value: 8)
      expect { HealthCheckJob.perform_now }.to change(Notification, :count).by(1)
      expect(Notification.last.title).to eq("Bateria baixa: Teste Bateria")
      expect { HealthCheckJob.perform_now }.not_to change(Notification, :count)
      Notification.delete_all
      Diagnostics.update_settings!(site, { "battery_notify" => "0" })
      expect { Diagnostics.notify!(tenant) }.not_to change(Notification, :count)
      expect(p).to be_persisted
    end
  end

  describe "reparos" do
    it "reconectar só lê (PollDeviceJob com reconnect) e varrer pede a varredura" do
      i = tuya_integration([])
      d = dev("Teste Tomada", driver: "tuya_local", status: "offline", last_seen_at: 3.hours.ago, integration: i, external_id: "q", address: { "host" => "192.168.0.3" })
      f = run.find { |x| x.rule.key == "offline" }
      expect(f.fixes).to include("reconnect", "scan")
      expect { Diagnostics.fix("reconnect").call(f, user: nil) }.to have_enqueued_job(PollDeviceJob).with(d.id, reconnect: true)
      expect { Diagnostics.fix("scan").call(f, user: nil) }.to have_enqueued_job(SyncIntegrationJob)
      expect(Command.count).to eq(0)
    end

    it "parear de novo só aparece com a rota configurada" do
      d = dev("Teste Zigbee", driver: "mqtt", status: "offline", last_seen_at: 3.hours.ago)
      expect(run.first.fixes).not_to include("pair")
      allow(Diagnostics).to receive(:config).and_return(Diagnostics.config.merge("pair_route" => "device_health"))
      f = run.first
      expect(f.fixes).to include("pair")
      expect(Diagnostics.fix("pair").url(f)).to include("site_id=#{site.id}", "device_id=#{d.id}")
    end
  end
end
