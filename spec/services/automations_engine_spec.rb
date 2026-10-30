require "rails_helper"

# Motor da DSL (F6) com as automações reais do HA da casa (spec/fixtures/automations).
RSpec.describe "Automações: motor da DSL" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, latitude: -15.79, longitude: -47.88) }
  let(:device) { create(:device, site: site, name: "Casa") }
  let(:p) { casa_points(site, device) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def cmd(point, command, value = nil) = Points::Command.call(point, command, value, source: "web", user: nil)
  def report(key, value) = p[key].reload.report!(value)
  # +1 s: o travel zera os microssegundos e o job agendado tem fração.
  def pass(duration)
    travel(duration + 1.second)
    perform_enqueued_jobs(at: Time.current)
  end

  def build(definition, mode: "single", **attrs)
    a = Automation.create!(site: site, name: "Teste", mode: mode, **attrs)
    a.publish!(definition)
    a.update!(enabled: true)
    a
  end

  # Ação simples que deixa rastro: aviso no app.
  def notify(title) = { "type" => "notify", "channels" => [ "in_app" ], "title" => title }
  def manual = [ { "type" => "manual" } ]

  describe "automações reais do HA (fixtures)" do
    %w[sala_movimento_pendente portao_alerta_escalonado bateria_baixa_eva hub_zigbee_offline webhook_ia_avisar cozinha_cena_portao].each do |name|
      it "#{name} é DSL válida e publica" do
        p
        a = ha_automation(site, name)
        expect(a.version).to eq(1)
        expect(Automations::Dsl.errors(a.definition, site)).to eq([])
      end
    end

    it "sala: movimento à noite acende o pendente e apaga depois de 2 min sem movimento" do
      travel_to Time.zone.parse("2026-10-29 20:00")
      p
      travel 5.minutes # luzes apagadas há mais de 60 s
      a = ha_automation(site, "sala_movimento_pendente")
      report("sala.camera_movimento", true)
      expect(p["cozinha.pendentes"].reload.value).to be true
      run = a.runs.sole
      expect(run.status).to eq("waiting")
      expect(run.steps.pluck("title")).to include("Condições atendidas", "Ligar Pendentes")
      expect(Command.last.automation_run_id).to eq(run.id)

      report("sala.camera_movimento", false)
      pass(1.minute)
      expect(run.reload.status).to eq("waiting") # ainda não fez 2 min
      report("sala.camera_movimento", true)      # mexeu de novo: conta recomeça
      report("sala.camera_movimento", false)
      pass(1.minute + 30.seconds)
      expect(p["cozinha.pendentes"].reload.value).to be true
      pass(1.minute)
      expect(p["cozinha.pendentes"].reload.value).to be false
      expect(run.reload.status).to eq("done")
      expect(a.reload).to have_attributes(last_status: "done")
    end

    it "sala: de dia ou com luz mexida há pouco não acende (condições no trace)" do
      travel_to Time.zone.parse("2026-10-29 14:00")
      p
      travel 5.minutes
      a = ha_automation(site, "sala_movimento_pendente")
      report("sala.camera_movimento", true)
      run = a.runs.sole
      expect(run.status).to eq("skipped")
      check = run.steps.find { |s| s["kind"] == "conditions" }["checks"].first
      expect(check).to include("label" => "Horário depois de 18:00, antes de 05:00", "result" => false, "values" => "agora: 14:05, qui")

      travel_to Time.zone.parse("2026-10-29 21:00")
      report("sala.camera_movimento", false)
      cmd(p["sala.sala_tv"], "on")
      cmd(p["sala.sala_tv"], "off") # apagou agora: a câmera "vê" a mudança de luz
      report("sala.camera_movimento", true)
      expect(a.runs.recent.first.status).to eq("skipped")
      expect(p["cozinha.pendentes"].reload.value).to be false
    end

    it "portão: avisa em 5, 10, 20 min e para quando fecha; reabrir reinicia a contagem" do
      p
      a = ha_automation(site, "portao_alerta_escalonado")
      report("garagem.sensor_portao", true)
      pass(5.minutes)
      expect(Notification.order(:created_at).last).to have_attributes(title: "ALERTA", body: "Portão aberto há 5 minutos.")
      pass(5.minutes)
      expect(Notification.order(:created_at).last.body).to eq("Portão aberto há 10 minutos.")
      pass(10.minutes)
      expect(Notification.order(:created_at).last.body).to eq("Portão aberto há 20 minutos.")

      report("garagem.sensor_portao", false)
      report("garagem.sensor_portao", true) # modo restart: cancela e recomeça
      expect(a.runs.where(status: "cancelled").count).to eq(1)
      expect(a.runs.where(status: "waiting").count).to eq(1)
      pass(5.minutes)
      expect(Notification.order(:created_at).last.body).to eq("Portão aberto há 5 minutos.")
      report("garagem.sensor_portao", false)
      pass(5.minutes)
      expect(a.runs.recent.first.status).to eq("stopped")
      expect(Notification.count).to eq(4)
    end

    it "portão: fase perpétua a cada 160 min com os minutos desde a abertura" do
      p
      a = ha_automation(site, "portao_alerta_escalonado")
      report("garagem.sensor_portao", true)
      6.times { |i| pass([ 5, 5, 10, 20, 40, 80 ][i].minutes) }
      expect(Notification.order(:created_at).last.body).to eq("Portão aberto há 160 minutos.")
      pass(160.minutes)
      expect(Notification.order(:created_at).last.body).to eq("Portão aberto há 320 minutos.")
      expect(a.runs.sole.steps.pluck("title")).to include("Repetir: fim (6 voltas)", "Repetir: volta 1")
    end

    it "bateria: cruzar 15% avisa; a cada 10 min repete; carregando ou ciente não avisa" do
      travel_to Time.zone.parse("2026-10-29 10:03")
      p
      ha_automation(site, "bateria_baixa_eva")
      report("eva.bateria", 14)
      expect(Notification.last).to have_attributes(title: "RECARREGUE O CELULAR", body: "Bateria em 14 % no Smartphone Eva!")
      travel_to Time.zone.parse("2026-10-29 10:10")
      Automations::Triggers.tick
      expect(Notification.count).to eq(2)
      travel_to Time.zone.parse("2026-10-29 10:11")
      Automations::Triggers.tick
      expect(Notification.count).to eq(2)
      report("eva.carregando", true)
      travel_to Time.zone.parse("2026-10-29 10:20")
      Automations::Triggers.tick
      expect(Notification.count).to eq(2)
    end

    it "hub zigbee: a cada 30 min avisa só se o hub estiver indisponível" do
      travel_to Time.zone.parse("2026-10-29 10:30")
      p
      a = ha_automation(site, "hub_zigbee_offline")
      Automations::Triggers.tick
      expect(a.runs.sole.status).to eq("skipped")
      p["cozinha.hub_zigbee"].report!(nil, quality: "unavailable")
      travel_to Time.zone.parse("2026-10-29 11:00")
      Automations::Triggers.tick
      expect(Notification.last).to have_attributes(title: "Hub Zigbee offline")
      expect(Notification.last.body).to start_with("Sem resposta às 11:00.")
    end

    it "webhook da IA: texto do JSON, canal escolhido, mensagem vazia não avisa" do
      p
      a = ha_automation(site, "webhook_ia_avisar")
      a.fire!({ "type" => "webhook", "data" => { "mensagem" => " Build verde ", "canal" => "ambos", "titulo" => "CI" } })
      expect(Notification.order(:created_at).pluck(:title, :body)).to eq([ [ "CI", "Build verde" ], [ "Anúncio pendente (Alexa na F8)", "Build verde" ] ])
      run = a.fire!({ "type" => "webhook", "data" => { "mensagem" => "" } })
      expect(run.status).to eq("stopped")
      expect(Notification.count).to eq(2)
    end

    it "cena da cozinha: pulsa o portão e desliga o interruptor (comandos com a causa)" do
      p
      a = ha_automation(site, "cozinha_cena_portao")
      cmd(p["cozinha.switch_cena"], "on")
      expect(p["garagem.portao_eletronico"].reload.value).to eq("open")
      expect(p["cozinha.switch_cena"].reload.value).to be false
      run = a.runs.sole
      expect(run.status).to eq("done")
      expect(Command.where(automation_run_id: run.id).pluck(:command)).to contain_exactly("pulse", "off")
      expect(run.steps.pluck("title")).to include("Acionar Portao eletronico", "Desligar Switch cena")
    end
  end

  describe "proteção contra laço e limites" do
    it "automação que mexe no próprio gatilho não dispara de novo (laço evitado no trace)" do
      p
      a = build({ "triggers" => [ { "type" => "state", "point" => p["sala.sala_tv"].id } ],
                  "actions" => [ { "type" => "command", "point" => p["sala.sala_tv"].id, "command" => "toggle" } ] })
      cmd(p["sala.sala_tv"], "on")
      expect(a.runs.pluck(:status)).to contain_exactly("done", "loop")
      expect(a.runs.find_by(status: "loop")).to have_attributes(depth: 1, error: start_with("Laço evitado: disparada pela própria ação"))
      expect(p["sala.sala_tv"].reload.value).to be false
    end

    it "corrente entre automações para no limite de profundidade" do
      p
      keys = %w[cozinha.iluminacao cozinha.sala_jantar sala.sala_estar sala.sala_tv cozinha.pendentes eva.alerta_reconhecido cozinha.switch_cena]
      keys.each_cons(2) do |from, to|
        build({ "triggers" => [ { "type" => "state", "point" => p[from].id, "to" => true } ],
                "actions" => [ { "type" => "command", "point" => p[to].id, "command" => "on" } ] })
      end
      cmd(p["cozinha.iluminacao"], "on")
      expect(AutomationRun.where(status: "done").count).to eq(Automation::MAX_DEPTH + 1)
      expect(AutomationRun.find_by(status: "loop").error).to include("corrente com mais de 3")
    end

    it "comando recente de automação num aparelho real conta como causa (sem thread)" do
      p
      a = build({ "triggers" => [ { "type" => "state", "point" => p["sala.sala_tv"].id } ], "actions" => [ notify("x") ] })
      first = a.fire!({ "type" => "manual" })
      Command.create!(site: site, point: p["sala.sala_tv"], command: "on", source: "automation", status: "confirmed", automation_run_id: first.id)
      p["sala.sala_tv"].report!(true)
      expect(a.runs.recent.first.status).to eq("loop")
    end

    it "mais de 30 execuções por minuto são ignoradas" do
      a = build({ "triggers" => manual, "actions" => [ notify("x") ] }, mode: "parallel")
      31.times { a.fire!({ "type" => "manual" }) }
      expect(a.runs.count).to eq(Automation::MAX_PER_MINUTE)
      expect(a.reload.last_error).to include("Mais de 30 execuções")
    end

    it "repetir enquanto sem fim para no limite de voltas" do
      p
      a = build({ "triggers" => manual, "actions" => [ { "type" => "repeat", "while" => [ { "type" => "expr", "expr" => "1 = 1" } ], "actions" => [ { "type" => "set", "var" => "n", "expr" => "repeat_index" } ] } ] })
      run = a.fire!({ "type" => "manual" })
      expect(run.status).to eq("done")
      expect(run.state["vars"]["n"]).to eq(100)
      expect(run.steps.pluck("title")).to include("Repetir: parou no limite de 100 voltas")
    end
  end

  describe "modos" do
    let(:waiting) { { "triggers" => manual, "actions" => [ { "type" => "wait", "for" => "1m" }, notify("fim") ] } }

    it "single ignora o disparo com outra rodando" do
      a = build(waiting)
      a.fire!({ "type" => "manual" })
      expect(a.fire!({ "type" => "manual" })).to be_nil
      expect(a.runs.count).to eq(1)
    end

    it "queued roda na ordem, uma depois da outra, até max_runs na fila" do
      a = build(waiting, mode: "queued", max_runs: 2)
      3.times { a.fire!({ "type" => "manual" }) }
      expect(a.fire!({ "type" => "manual" })).to be_nil
      expect(a.runs.pluck(:status).tally).to eq("waiting" => 1, "queued" => 2)
      pass(1.minute)
      expect(a.runs.pluck(:status).tally).to eq("done" => 1, "waiting" => 1, "queued" => 1)
      pass(1.minute)
      pass(1.minute)
      expect(a.runs.pluck(:status).tally).to eq("done" => 3)
      expect(Notification.count).to eq(3)
    end

    it "parallel roda junto até max_runs" do
      a = build(waiting, mode: "parallel", max_runs: 2)
      3.times { a.fire!({ "type" => "manual" }) }
      expect(a.runs.where(status: "waiting").count).to eq(2)
    end

    it "execução rodando parada há muito (processo caiu) não segura o single" do
      a = build(waiting)
      a.fire!({ "type" => "manual" }).update_columns(status: "running", updated_at: 10.minutes.ago)
      expect(a.fire!({ "type" => "manual" })).to be_present
    end
  end

  describe "espera sobrevive a reinício" do
    it "retoma pelo job agendado, com variáveis e posição; job velho não retoma" do
      a = build({ "triggers" => manual, "actions" => [
                  { "type" => "set", "var" => "x", "expr" => "2 + 3" }, { "type" => "wait", "for" => "10m" },
                  { "type" => "notify", "channels" => [ "in_app" ], "title" => "x vale {{ x }}" } ] })
      run = a.fire!({ "type" => "manual" })
      expect(run).to have_attributes(status: "waiting", state: include("pc" => 2, "vars" => { "x" => 5 }, "seq" => 1))
      job = enqueued_jobs.find { |j| j["job_class"] == "AutomationResumeJob" }
      expect(job["arguments"]).to eq([ run.id, 1 ])
      expect(job["scheduled_at"]).to be_present
      clear_enqueued_jobs
      # "reinício": nada em memória, só o banco e o job.
      AutomationResumeJob.perform_now(run.id, 0)
      expect(run.reload.status).to eq("waiting")
      travel(10.minutes)
      AutomationResumeJob.perform_now(run.id, 1)
      expect(run.reload.status).to eq("done")
      expect(Notification.last.title).to eq("x vale 5")
      AutomationResumeJob.perform_now(run.id, 1)
      expect(Notification.count).to eq(1)
    end

    it "esperar condição: tempo limite segue ou para conforme a opção" do
      p
      cond = [ { "type" => "state", "point" => p["sala.sala_tv"].id, "is" => true } ]
      a = build({ "triggers" => manual, "actions" => [ { "type" => "wait_for", "conditions" => cond, "timeout" => "5m" }, notify("seguiu") ] })
      run = a.fire!({ "type" => "manual" })
      pass(5.minutes)
      expect(run.reload.status).to eq("done")
      expect(run.steps.pluck("title")).to include("Tempo limite da espera")

      b = build({ "triggers" => manual, "actions" => [ { "type" => "wait_for", "conditions" => cond, "timeout" => "5m", "continue_on_timeout" => false }, notify("não") ] })
      run = b.fire!({ "type" => "manual" })
      pass(1.minute)
      cmd(p["sala.sala_tv"], "on")
      expect(run.reload.status).to eq("done") # a mudança do ponto retoma na hora
      cmd(p["sala.sala_tv"], "off")
      run = b.fire!({ "type" => "manual" })
      pass(5.minutes)
      expect(run.reload).to have_attributes(status: "stopped", error: "Tempo limite da espera")
    end

    it "versão publicada depois da espera: retoma com a versão em que começou" do
      a = build({ "triggers" => manual, "actions" => [ { "type" => "wait", "for" => "1m" }, notify("v1") ] })
      run = a.fire!({ "type" => "manual" })
      a.publish!({ "triggers" => manual, "actions" => [ notify("v2") ] })
      pass(1.minute)
      expect(run.reload.status).to eq("done")
      expect(Notification.last.title).to eq("v1")
    end
  end

  describe "gatilhos" do
    before { p }

    it "estado com 'por': só dispara se ficou o tempo todo" do
      a = build({ "triggers" => [ { "type" => "state", "point" => p["garagem.sensor_portao"].id, "to" => true, "for" => "5m" } ], "actions" => [ notify("aberto") ] })
      report("garagem.sensor_portao", true)
      pass(2.minutes)
      report("garagem.sensor_portao", false)
      report("garagem.sensor_portao", true)
      pass(4.minutes)
      expect(a.runs.count).to eq(0)
      pass(1.minute)
      expect(a.runs.sole.trigger["title"]).to include("há 5 min")
    end

    it "limite numérico: dispara ao cruzar, não enquanto continua acima" do
      a = build({ "triggers" => [ { "type" => "numeric", "point" => p["eva.bateria"].id, "above" => 90 } ], "actions" => [ notify("cheia") ] })
      report("eva.bateria", 95)
      report("eva.bateria", 96)
      report("eva.bateria", 50)
      report("eva.bateria", 91)
      expect(a.runs.count).to eq(2)
    end

    it "horário com dias e sol com deslocamento" do
      a = build({ "triggers" => [ { "type" => "time", "at" => "12:00", "days" => [ 1, 2, 3, 4, 5 ] } ], "actions" => [ notify("12h") ] })
      sun = build({ "triggers" => [ { "type" => "sun", "event" => "sunset", "offset" => "-15m" } ], "actions" => [ notify("sol") ] })
      Automations::Triggers.tick(Time.zone.parse("2026-10-29 12:00")) # quinta
      Automations::Triggers.tick(Time.zone.parse("2026-10-31 12:00")) # sábado
      expect(a.runs.count).to eq(1)
      sunset = Sun.at("sunset", Date.new(2026, 10, 29), site.latitude, site.longitude, Time.zone) - 15.minutes
      Automations::Triggers.tick(sunset)
      expect(sun.runs.count).to eq(1)
    end

    it "alerta: abriu e ciente disparam a automação" do
      rule = AlertRule.create!(site: site, point: p["garagem.sensor_portao"], name: "Portão aberto", operator: "eq", value: true)
      a = build({ "triggers" => [ { "type" => "alert", "rule" => rule.id, "on" => "open" }, { "type" => "alert", "rule" => rule.id, "on" => "ack" } ],
                  "actions" => [ { "type" => "notify", "channels" => [ "in_app" ], "title" => "{{ trigger.title }}" } ] })
      report("garagem.sensor_portao", true)
      expect(a.runs.count).to eq(1)
      rule.alerts.sole.ack!(create(:user, tenant: tenant))
      expect(a.runs.count).to eq(2)
      expect(Notification.where(kind: "automacao").pluck(:title)).to include("Alerta Portão aberto: abriu", "Alerta Portão aberto: alguém marcou ciente")
    end

    it "desligada ou valor que voltou com a conexão não dispara" do
      a = build({ "triggers" => [ { "type" => "state", "point" => p["sala.sala_tv"].id } ], "actions" => [ notify("x") ] })
      a.update!(enabled: false)
      cmd(p["sala.sala_tv"], "on")
      a.update!(enabled: true)
      p["sala.sala_tv"].reload.report!(true, quality: "unavailable")
      p["sala.sala_tv"].report!(false)
      expect(a.runs.count).to eq(0)
    end
  end

  describe "condições e ações" do
    before { p }

    it "e/ou/não, numérico, sol, expressão com erro e janela de dias" do
      travel_to Time.zone.parse("2026-10-29 22:30")
      a = build({ "triggers" => manual,
                  "conditions" => [
                    { "type" => "or", "conditions" => [ { "type" => "numeric", "point" => p["eva.bateria"].id, "above" => 90 }, { "type" => "numeric", "point" => p["eva.bateria"].id, "above" => 10, "below" => 81 } ] },
                    { "type" => "not", "conditions" => [ { "type" => "state", "point" => p["sala.sala_tv"].id, "is" => true } ] },
                    { "type" => "sun", "after" => "sunset", "before" => "sunrise" },
                    { "type" => "time", "after" => "22:00", "days" => [ 4 ] },
                    { "type" => "expr", "expr" => "eva.bateria > 50 and hour >= 22" }
                  ], "actions" => [ notify("ok") ] })
      expect(a.fire!({ "type" => "manual" }).status).to eq("done")

      b = build({ "triggers" => manual, "conditions" => [ { "type" => "expr", "expr" => "nao.existe > 1" } ], "actions" => [ notify("x") ] })
      run = b.fire!({ "type" => "manual" })
      expect(run.status).to eq("skipped")
      expect(run.steps.last["checks"].first["values"]).to include("não é ponto deste local")
    end

    it "se/senão, escolher, repetir até, cena, parar com erro" do
      scene = Scene.create!(site: site, name: "Noite", items: [ { "point_id" => p["sala.sala_tv"].id, "command" => "on" } ])
      a = build({ "triggers" => manual, "actions" => [
                  { "type" => "set", "var" => "n", "expr" => "0" },
                  { "type" => "repeat", "until" => [ { "type" => "expr", "expr" => "n >= 3" } ], "actions" => [ { "type" => "set", "var" => "n", "expr" => "n + 1" } ] },
                  { "type" => "if", "conditions" => [ { "type" => "expr", "expr" => "n = 3" } ], "then" => [ notify("três") ], "else" => [ notify("errado") ] },
                  { "type" => "choose", "options" => [
                    { "conditions" => [ { "type" => "expr", "expr" => "n > 5" } ], "actions" => [ notify("maior") ] },
                    { "conditions" => [ { "type" => "expr", "expr" => "n > 2" } ], "actions" => [ { "type" => "scene", "scene" => scene.id } ] }
                  ], "default" => [ notify("nenhuma") ] },
                  { "type" => "stop", "reason" => "acabou", "error" => true },
                  notify("nunca")
                ] })
      run = a.fire!({ "type" => "manual" })
      expect(Notification.pluck(:title)).to eq([ "três" ])
      expect(p["sala.sala_tv"].reload.value).to be true
      expect(run).to have_attributes(status: "failed", error: "acabou")
      expect(run.steps.pluck("title")).to include("Opção 1: não", "Opção 2: sim", "Acionar cena Noite", "Parar: acabou")
    end

    it "comando que falha marca a execução com falha e o erro na lista" do
      a = build({ "triggers" => manual, "actions" => [ { "type" => "command", "point" => p["sala.sala_tv"].id, "command" => "on" } ] })
      p["sala.sala_tv"].update!(disabled: true)
      run = a.fire!({ "type" => "manual" })
      expect(run).to have_attributes(status: "failed", error: "Ponto desativado.")
      expect(a.reload.last_error).to eq("Ponto desativado.")
    end

    it "executar agora ignora as condições" do
      a = build({ "triggers" => manual, "conditions" => [ { "type" => "expr", "expr" => "1 = 2" } ], "actions" => [ notify("foi") ] })
      expect(a.fire!({ "type" => "manual" }, skip_conditions: true).status).to eq("done")
      expect(a.fire!({ "type" => "manual" }).status).to eq("skipped")
    end
  end

  describe "simulação" do
    before { p }

    it "roda a seco com valores e hora hipotéticos: não comanda nem avisa" do
      a = Automation.create!(site: site, name: "Pendente")
      a.update!(draft: ha_fixture("sala_movimento_pendente")["definition"])
      run = a.simulate!(points: { "sala.camera_movimento" => "true" }, at: "2026-10-29 21:00")
      expect(run).to have_attributes(dry_run: true, status: "done")
      expect(Command.count).to eq(0)
      titles = run.steps.pluck("title")
      expect(titles).to include("Condições atendidas", "Ligar Pendentes", "Esperar condição: não se cumpre na simulação", "Seguir só se: sim", "Desligar Pendentes")
      expect(run.steps.find { |s| s["title"] == "Ligar Pendentes" }).to include("result" => "simulated")

      day = a.simulate!(at: "2026-10-29 12:00")
      expect(day.status).to eq("skipped")
      expect(a.runs.real.count).to eq(0)
    end

    it "aviso e espera simulados mostram o texto montado" do
      a = Automation.create!(site: site, name: "Portão")
      a.update!(draft: ha_fixture("portao_alerta_escalonado")["definition"])
      run = a.simulate!(points: { "garagem.sensor_portao" => true })
      expect(Notification.count).to eq(0)
      expect(run.steps.pluck("title")).to include("Esperar 5 min", "Avisar: ALERTA")
      expect(run.steps.find { |s| s["title"] == "Avisar: ALERTA" }["detail"]).to include("Portão aberto há 5 minutos.")
    end

    it "erro de expressão na simulação vira falha no trace" do
      a = Automation.create!(site: site, name: "x", draft: { "triggers" => manual, "actions" => [ { "type" => "wait", "expr" => "x * 2" } ] })
      run = a.simulate!
      expect(run).to have_attributes(status: "failed", error: include("\"x\" não é ponto"))
    end
  end

  describe "validação da DSL" do
    before { p }

    it "aponta tipo, campo, ponto, duração, expressão, texto e comando inválidos" do
      errors = Automations::Dsl.errors({
        "triggers" => [ { "type" => "nada" }, { "type" => "time" }, { "type" => "state", "point" => "x.y" } ],
        "conditions" => [ { "type" => "expr", "expr" => "1 +" }, { "type" => "state", "point" => p["sala.sala_tv"].id } ],
        "actions" => [ { "type" => "wait", "for" => "5 minutos" }, { "type" => "notify", "title" => "{{ x" },
                       { "type" => "command", "point" => p["eva.bateria"].id, "command" => "on" },
                       { "type" => "command", "point" => p["sala.sala_tv"].id, "command" => "pulse", "extra" => 1 },
                       { "type" => "repeat", "count" => 500, "actions" => [] } ],
        "outro" => 1
      }, site)
      expect(errors.join("\n")).to include(
        "Chave desconhecida: outro", "gatilhos 1: tipo \"nada\" não existe", "gatilhos 2 (Horário): use \"às\", \"a cada\" ou \"no horário do ponto\" (só um)",
        "gatilhos 3 (Ponto mudou): ponto: ponto não existe", "condições 1 (Expressão): expressão", "condições 2 (Ponto está): informe o valor",
        "ações 1 (Esperar): tempo (ex.: 5m): duração inválida", "ações 2 (Avisar): título: texto inválido", "Bateria não recebe comando",
        "campo desconhecido extra", "no máximo 100 vezes"
      )
    end

    it "aceita key no lugar do UUID e converte o valor para o tipo do ponto" do
      a = Automation.create!(site: site, name: "x")
      a.publish!({ "triggers" => [ { "type" => "state", "point" => "sala.sala_tv", "to" => "true" } ], "actions" => [ notify("x") ] })
      expect(a.definition["triggers"].first).to eq("type" => "state", "point" => p["sala.sala_tv"].id, "to" => true)
      expect(Automations::Dsl.with_keys(a.definition, site)["triggers"].first["point"]).to eq("sala.sala_tv")
    end

    it "não publica definição incompleta nem liga sem publicar" do
      a = Automation.create!(site: site, name: "x")
      expect { a.publish!({ "triggers" => [], "actions" => [] }) }.to raise_error(ActiveRecord::RecordInvalid, /Falta pelo menos um gatilho/)
      expect(a.update(enabled: true)).to be false
      expect(Automations::Dsl.seconds("1h30m")).to eq(5400)
      expect(Automations::Dsl.seconds("-15m")).to eq(-900)
      expect(Automations::Dsl.duration_label(5430)).to eq("1 h 30 min 30 s")
    end

    it "volta versão: a antiga é publicada de novo como a próxima" do
      a = build({ "triggers" => manual, "actions" => [ notify("v1") ] })
      a.publish!({ "triggers" => manual, "actions" => [ notify("v2") ] })
      a.revert!(1)
      expect(a.reload.version).to eq(3)
      expect(a.definition["actions"].first["title"]).to eq("v1")
      expect(a.versions.pluck(:version)).to eq([ 3, 2, 1 ])
    end

    it "retenção: apaga execuções velhas e as além do limite por automação" do
      a = build({ "triggers" => manual, "actions" => [ notify("x") ] })
      old = a.runs.create!(site: site, started_at: 40.days.ago, status: "done", created_at: 40.days.ago)
      stub_const("AutomationRun::KEEP", 2)
      3.times { |i| a.runs.create!(site: site, started_at: Time.current, status: "done", created_at: i.minutes.ago) }
      AutomationRun.prune!
      expect(a.runs.count).to eq(2)
      expect(AutomationRun.exists?(old.id)).to be false
    end
  end
end
