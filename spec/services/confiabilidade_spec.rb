require "rails_helper"

# Confiabilidade (docs/confiabilidade.md): nova tentativa só quando nada saiu,
# anúncio único por conta da Alexa, execuções sem dono, aparelho sem sinal e
# avisos de falha repetida. Nada sai para a rede (WebMock / drivers falsos).
RSpec.describe "Confiabilidade" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:device) { create(:device, site: site, driver: "tuya_local", name: "Tomada") }
  let(:point) { create(:point, device: device, name: "Liga", value: false) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  # Driver falso: cada chamada pega o próximo da lista (erro = levanta).
  def fake_driver(*results)
    calls = []
    driver = Object.new
    driver.define_singleton_method(:execute) do |p, c, v|
      calls << [ p.id, c, v ]
      r = results.shift
      raise r if r.is_a?(Exception)
    end
    driver.define_singleton_method(:calls) { calls }
    allow(Drivers).to receive(:for).and_return(driver)
    driver
  end

  def wrapped(error, as: Tuya::Cloud::Error, message: "Sem conexão com a Tuya")
    raise error
  rescue StandardError
    begin
      raise as, message
    rescue StandardError => e
      e
    end
  end

  def command(source: "automation") = Points::Command.call(point, "on", nil, source: source, user: nil)
  def enqueued_executes = enqueued_jobs.select { |j| j["job_class"] == "ExecuteCommandJob" }

  describe Transient do
    it "repete só quando a conexão nem abriu ou o serviço recusou sem efeito" do
      expect(described_class.retryable?(Net::OpenTimeout.new)).to be true
      expect(described_class.retryable?(Errno::EHOSTUNREACH.new)).to be true
      expect(described_class.retryable?(SocketError.new("getaddrinfo"))).to be true
      expect(described_class.retryable?(wrapped(Net::OpenTimeout.new))).to be true # "Sem conexão com a Tuya (OpenTimeout)"
      expect(described_class.retryable?(OpenSSL::SSL::SSLError.new("SSL_connect returned=1 errno=0"))).to be true
      expect(described_class.retryable?(Tuya::Connection::ConnectError.new("sem conexão"))).to be true

      expect(described_class.retryable?(Net::ReadTimeout.new)).to be false # pode ter chegado
      expect(described_class.retryable?(wrapped(Net::ReadTimeout.new))).to be false
      expect(described_class.retryable?(OpenSSL::SSL::SSLError.new("SSL_read: unexpected eof"))).to be false
      expect(described_class.retryable?(Errno::ECONNRESET.new)).to be false
      expect(described_class.retryable?(RuntimeError.new("o aparelho recusou"))).to be false
      expect(described_class.retryable?(Tuya::Connection::Error.new("conexão caiu"))).to be false
    end

    it "recusa 429/5xx repete, mas não em ponto crítico; Retry-After vale mais que a tabela" do
      busy = Alexa::Client::Busy.new("A Alexa respondeu 429.", status: 429, retry_after: 7)
      expect(described_class.retryable?(busy)).to be true
      expect(described_class.retryable?(busy, strict: true)).to be false
      expect(described_class.retryable?(Net::OpenTimeout.new, strict: true)).to be true
      expect(described_class.retryable?(Alexa::Client::Busy.new("x", status: 500))).to be false
      expect(described_class.wait(1)).to eq(5)
      expect(described_class.wait(2)).to eq(30)
      expect(described_class.wait(3)).to eq(120)
      expect(described_class.wait(4)).to be_nil
      expect(described_class.wait(1, busy)).to eq(7)
      expect(described_class.parse_retry_after("12")).to eq(12)
      expect(described_class.parse_retry_after((Time.now + 20).httpdate)).to be_between(18, 21)
      expect(described_class.parse_retry_after("lixo")).to be_nil
    end

    it "with_retry repete na hora só a conexão que não abriu" do
      tries = 0
      expect(described_class.with_retry { (tries += 1) == 1 ? raise(Net::OpenTimeout) : :ok }).to eq(:ok)
      expect(tries).to eq(2)
      tries = 0
      expect { described_class.with_retry { tries += 1; raise Net::ReadTimeout } }.to raise_error(Net::ReadTimeout)
      expect(tries).to eq(1)
    end
  end

  describe ExecuteCommandJob do
    it "falha passageira volta para a fila (5 s, depois 30 s) e confirma na tentativa seguinte" do
      driver = fake_driver(wrapped(Net::OpenTimeout.new), wrapped(Net::OpenTimeout.new), nil)
      c = command
      described_class.perform_now(c.id)
      expect(c.reload).to have_attributes(status: "pending", attempts: 1, error: /Tentativa 1 falhou: Sem conexão/)
      job = enqueued_executes.last
      expect(Time.zone.at(job["scheduled_at"].is_a?(String) ? Time.zone.parse(job["scheduled_at"]) : job["scheduled_at"])).to be_within(2.seconds).of(5.seconds.from_now)

      travel(6.seconds)
      described_class.perform_now(c.id)
      expect(c.reload).to have_attributes(status: "pending", attempts: 2)
      travel(31.seconds)
      described_class.perform_now(c.id)
      expect(c.reload).to have_attributes(status: "confirmed", attempts: 3)
      expect(driver.calls.size).to eq(3)
    end

    it "nunca passa do Command::TTL: sem tempo para a próxima, falha com o número de tentativas" do
      fake_driver(Net::OpenTimeout.new, Net::OpenTimeout.new)
      c = command
      described_class.perform_now(c.id)
      travel(40.seconds) # a próxima seria em 30 s: 70 s > TTL de 60 s
      described_class.perform_now(c.id)
      expect(c.reload).to have_attributes(status: "failed", attempts: 2, error: /2 tentativas/)
    end

    it "nova tentativa que chega tarde à fila falha (não expira calada)" do
      fake_driver(Net::OpenTimeout.new)
      c = command
      described_class.perform_now(c.id)
      travel(2.minutes)
      described_class.perform_now(c.id)
      expect(c.reload).to have_attributes(status: "failed", attempts: 1, error: /prazo esgotado/)
    end

    it "não repete leitura estourada, erro desconhecido nem recusa do aparelho" do
      [ Net::ReadTimeout.new, RuntimeError.new("o aparelho recusou"), wrapped(Net::ReadTimeout.new) ].each do |err|
        driver = fake_driver(err)
        c = command
        described_class.perform_now(c.id)
        expect(c.reload).to have_attributes(status: "failed", attempts: 1)
        expect(driver.calls.size).to eq(1)
      end
      expect(enqueued_executes.count { |j| j["scheduled_at"] }).to eq(0)
    end

    it "ponto crítico (portão) só repete conexão que nem abriu" do
      point.update!(risk: "critical")
      fake_driver(Alexa::Client::Busy.new("503", status: 503))
      c = command
      described_class.perform_now(c.id)
      expect(c.reload.status).to eq("failed")
      fake_driver(Errno::ECONNREFUSED.new)
      c = command
      described_class.perform_now(c.id)
      expect(c.reload.status).to eq("pending")
    end
  end

  describe "aparelho sem sinal" do
    before { device.update!(status: "offline", last_seen_at: 3.days.ago) }

    it "automação não comanda (pulado, sem driver); pessoa ainda tenta" do
      driver = fake_driver(nil)
      c = command
      expect(c).to have_attributes(status: "skipped", error: "Aparelho sem sinal há 3 dias: comando não enviado.")
      expect(enqueued_executes).to be_empty
      expect(driver.calls).to be_empty
      expect(command(source: "web").status).to eq("pending")
      expect(Command::STATUSES["skipped"]).to be_present
    end

    it "recente ou com contato dentro do limite não pula; o limite é da instalação" do
      device.update!(last_seen_at: 2.hours.ago)
      expect(command.status).to eq("pending")
      tenant.update!(settings: tenant.settings.merge("reliability" => { "dead_device_hours" => 1 }))
      device.tenant.reload
      expect(command.status).to eq("skipped")
      expect(Reliability.duration_text(2.hours)).to eq("2 h")
    end

    it "comandos falhando seguidos também contam, mesmo com o status online" do
      device.update!(status: "online")
      expect(Reliability.signal_lost(device)).to be_nil
      3.times { Command.create!(site: site, point: point, command: "on", source: "web", status: "failed", error: "No route to host") }
      expect(Reliability.signal_lost(device)).to be > 2.days
    end

    it "no trace da automação vira passo pulado e a execução segue" do
      light = create(:point, device: create(:device, site: site, driver: "tuya_local"), name: "Luz boa", value: false)
      a = Automation.create!(site: site, name: "Dois", mode: "single")
      a.publish!({ "triggers" => [ { "type" => "manual" } ],
                   "actions" => [ { "type" => "command", "point" => point.id, "command" => "on" }, { "type" => "command", "point" => light.id, "command" => "on" } ] })
      a.update!(enabled: true)
      run = a.fire!({ "type" => "manual" })
      step = run.steps.find { |s| s["result"] == "skipped" }
      expect(step["detail"]).to match(/sem sinal há 3 dias/)
      expect(run.status).to eq("done")
      expect(light.commands.sole.status).to eq("pending")
    end
  end

  describe "Alexa" do
    let(:integration) do
      Integration.create!(site: site, driver: "alexa", name: "Alexa", status: "ok", settings: { "host" => "alexa.amazon.com.br" },
                          credentials: { "cookies" => { "session-id" => "S1", "csrf" => "C1" } }.to_json)
    end
    let(:echos) do
      { "Echo Escritório" => "G0E", "Echo Cozinha" => "G0C" }.map do |name, serial|
        d = create(:device, site: site, driver: "alexa", name: name, integration: integration, external_id: serial,
                            address: { "device_type" => "A3EH", "customer_id" => "CUST" })
        create(:point, device: d, name: "Fala", capability: "speaker", writable: true)
      end
    end
    let(:preview) { "https://alexa.amazon.com.br/api/behaviors/preview" }

    def notify_both = Notifier.deliver!(echos.map { |p| "alexa:#{p.id}" }, kind: "automacao", title: "Portão aberto")
    def sent_devices(req) = JSON.parse(JSON.parse(req.body)["sequenceJson"]).dig("startNode", "operationPayload", "target", "devices")

    it "um aviso para duas Echo da mesma conta vira UM anúncio com as duas, e a trilha tem um comando por Echo" do
      bodies = []
      stub_request(:post, preview).to_return { |req| bodies << req; { body: "" } }
      notify_both
      cmds = Command.where(point_id: echos.map(&:id)).order(:created_at)
      expect(cmds.size).to eq(2)
      lead = cmds.find { |c| c.batch_id == c.id }
      expect(cmds.map(&:batch_id).uniq).to eq([ lead.id ])
      expect(enqueued_executes.size).to eq(1)
      ExecuteCommandJob.perform_now(lead.id)
      expect(bodies.size).to eq(1)
      expect(sent_devices(bodies.first).pluck("deviceSerialNumber")).to contain_exactly("G0E", "G0C")
      expect(cmds.map { |c| c.reload.status }).to eq(%w[confirmed confirmed])
    end

    it "429 com Retry-After: o lote volta para a fila no prazo pedido e a conta não fica com erro" do
      stub_request(:post, preview).to_return({ status: 429, headers: { "Retry-After" => "4" } }, { body: "" })
      notify_both
      lead = Command.where.not(batch_id: nil).find { |c| c.batch_id == c.id }
      ExecuteCommandJob.perform_now(lead.id)
      expect(Command.where(batch_id: lead.id).pluck(:status, :attempts)).to all(eq([ "pending", 1 ]))
      expect(integration.reload.status).to eq("ok")
      travel(5.seconds)
      ExecuteCommandJob.perform_now(lead.id)
      expect(Command.where(batch_id: lead.id).pluck(:status)).to all(eq("confirmed"))
    end

    it "a ação Falar também agrupa; Echo de outra conta vai à parte" do
      other = Integration.create!(site: site, driver: "alexa", name: "Outra", status: "ok", credentials: { "cookies" => { "csrf" => "X" } }.to_json)
      third = create(:point, device: create(:device, site: site, driver: "alexa", name: "Echo Mãe", integration: other, external_id: "Z1",
                                                     address: { "device_type" => "A3EH", "customer_id" => "MAE" }), capability: "speaker", writable: true)
      Notifier.speak!((echos + [ third ]).map { |p| "alexa:#{p.id}" }, "Oi")
      expect(enqueued_executes.size).to eq(2)
      expect(Command.where(point_id: echos.map(&:id)).distinct.count(:batch_id)).to eq(1)
      expect { Notifier.speak!([ "alexa:#{SecureRandom.uuid}" ], "Oi") }.to raise_error(Points::Command::Error, /removida/)
    end

    it "pedidos da mesma conta saem espaçados" do
      Alexa::Throttle.gap = 0.05
      Alexa::Throttle.wait("conta")
      expect(Alexa::Throttle.wait("conta")).to be > 0
      expect(Alexa::Throttle.wait("outra")).to eq(0)
      Alexa::Throttle.hold("conta", 0.2)
      expect(Alexa::Throttle.wait("conta")).to be >= 0.1
    end
  end

  describe "nuvem" do
    it "Tuya: conexão que não abriu repete na hora; 503 vira recusa repetível" do
      stub_request(:get, "https://apigw.iotbing.com/x").to_timeout.then.to_return(body: { "success" => true }.to_json)
      expect(Tuya::Cloud.http(:get, "https://apigw.iotbing.com/x")).to eq("success" => true)
      stub_request(:get, "https://apigw.iotbing.com/y").to_return(status: 503, headers: { "Retry-After" => "9" })
      expect { Tuya::Cloud.http(:get, "https://apigw.iotbing.com/y") }.to raise_error(Tuya::Cloud::Busy) { |e| expect(Transient.wait(1, e)).to eq(9) }
    end
  end

  describe SendPushJob do
    let!(:owner) { create(:user, tenant: tenant, role: "owner") }

    it "tenta de novo só os aparelhos em que nada chegou" do
      got = []
      fake = Module.new do
        define_singleton_method(:configured?) { true }
        define_singleton_method(:capabilities) { %i[text] }
        define_singleton_method(:deliver) { |_u, _m| nil }
        define_singleton_method(:deliver_some) do |_u, _m, ids|
          got << ids
          ids ? [] : %w[a1]
        end
      end
      stub_const("Push::Pombo", fake)
      stub_const("Push::TRANSPORTS", %w[Pombo])
      n = Notifier.notify!(kind: "aviso", title: "T", push: false)
      described_class.perform_now(n.id)
      job = enqueued_jobs.find { |j| j["job_class"] == "SendPushJob" }
      expect(job).to be_present
      perform_enqueued_jobs(only: described_class)
      expect(got).to eq([ nil, %w[a1] ])
    end

    it "FCM: conexão que não abriu é repetível; o aparelho seguinte recebe" do
      allow(Push::FcmService).to receive(:configured?).and_return(true)
      t1 = owner.device_tokens.create!(token: "t1", platform: "android")
      owner.device_tokens.create!(token: "t2", platform: "android")
      allow(Push::FcmService).to receive(:deliver_data) { |token, **| token == "t1" ? raise(Net::OpenTimeout) : true }
      n = Notifier.notify!(kind: "aviso", title: "T", push: false)
      expect(Push::Fcm.deliver_some(owner, Push::Message.new(n, owner), nil)).to eq([ t1.id ])
    end
  end

  describe "execuções sem dono" do
    def build(mode: "single")
      a = Automation.create!(site: site, name: "Fila", mode: mode, max_runs: 5)
      a.publish!({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "notify", "channels" => [ "in_app" ], "title" => "oi" } ] })
      a.update!(enabled: true)
      a
    end

    it "rodando sem atualizar vira interrompida, com passo no trace, e a fila anda" do
      a = build(mode: "queued")
      stuck = a.runs.create!(site: site, trigger: { "type" => "manual" }, status: "running", started_at: 1.hour.ago)
      stuck.update_columns(updated_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations
      queued = a.runs.create!(site: site, trigger: { "type" => "manual" }, status: "queued", started_at: 30.minutes.ago)
      out = Automations::Sweeper.sweep!
      expect(out[:interrupted]).to eq(1)
      expect(stuck.reload).to have_attributes(status: "interrupted", finished_at: be_present, error: /parou sem terminar/)
      expect(stuck.steps.last).to include("kind" => "interrupted", "result" => "error")
      expect(stuck.status_label).to eq("Interrompida")
      expect(queued.reload.status).to eq("done")
      expect(a.reload.last_status).to eq("done")
    end

    it "no início do worker fecha o que rodava antes dele; o que a web começou depois fica" do
      a = build
      old = a.runs.create!(site: site, trigger: {}, status: "running", started_at: 3.minutes.ago)
      old.update_columns(updated_at: 3.minutes.ago) # rubocop:disable Rails/SkipsModelValidations
      fresh = a.runs.create!(site: site, trigger: {}, status: "running", started_at: Time.current)
      AutomationSweepJob.perform_now(1.minute.ago.iso8601(3))
      expect(old.reload.status).to eq("interrupted")
      expect(fresh.reload.status).to eq("running")
    end

    it "espera vencida há pouco retoma; vencida há muito fecha em vez de agir fora de hora" do
      a = build
      soon = a.runs.create!(site: site, trigger: {}, status: "waiting", started_at: 10.minutes.ago, resume_at: 5.minutes.ago, state: { "seq" => 3 })
      late = a.runs.create!(site: site, trigger: {}, status: "waiting", started_at: 2.days.ago, resume_at: 1.day.ago, state: { "seq" => 1 })
      Automations::Sweeper.sweep!
      job = enqueued_jobs.find { |j| j["job_class"] == "AutomationResumeJob" }
      expect(job["arguments"]).to eq([ soon.id, 3 ])
      expect(late.reload).to have_attributes(status: "interrupted", error: /não foi retomada/)
    end
  end

  describe "Saúde e avisos de falha repetida" do
    let!(:owner) { create(:user, tenant: tenant, role: "owner") }

    def items = Health::Checks::Reliability.items(tenant)

    it "ponto com 3 comandos seguidos falhando e automação com 3 execuções sem concluir viram erro (um aviso por dia)" do
      3.times { Command.create!(site: site, point: point, command: "on", source: "automation", status: "failed", error: "Sem conexão com a Tuya (OpenTimeout)") }
      a = Automation.create!(site: site, name: "Portão", mode: "single")
      %w[failed interrupted failed].each_with_index do |s, i|
        a.runs.create!(site: site, trigger: {}, status: s, started_at: (10 - i).minutes.ago, finished_at: (10 - i).minutes.ago, error: "falhou #{i}")
      end
      keys = items.select { |i| i.status == "error" }.map(&:key)
      expect(keys).to contain_exactly("point:#{point.id}", "automation:#{a.id}")
      expect { Health.alert!(tenant) }.to change(Notification, :count).by(2)
      expect { Health.alert!(tenant) }.not_to change(Notification, :count)
      expect(Notification.order(:created_at).last.dedup_key).to include(Date.current.to_s)
    end

    it "sucesso no meio quebra a sequência; aparelho sem sinal só informa; pico de falhas é erro" do
      2.times { Command.create!(site: site, point: point, command: "on", source: "web", status: "failed") }
      Command.create!(site: site, point: point, command: "on", source: "web", status: "confirmed")
      Command.create!(site: site, point: point, command: "on", source: "web", status: "failed")
      expect(items.find { |i| i.key == "streaks" }.status).to eq("ok")
      device.update!(status: "offline", last_seen_at: 2.days.ago)
      dead = items.find { |i| i.key == "#{site.id}:dead" }
      expect(dead).to have_attributes(status: "warn", detail: /Tomada \(2 dias\)/)
      expect(items.find { |i| i.key == "spike" }.status).to eq("ok")
      10.times { Command.create!(site: site, point: point, command: "on", source: "web", status: "failed") }
      expect(items.find { |i| i.key == "spike" }.status).to eq("error")
      expect(Health::CHECKS).to include("Reliability")
    end

    it "fila parada: o vigia avisa de fora do worker, com o push na hora" do
      allow(Health::Checks::Queues).to receive(:items).and_return([ Health::Item.new(key: "delay", status: "error", title: "Atraso", detail: "400 s") ])
      allow(FeatureFlag).to receive(:on?).and_call_original
      allow(FeatureFlag).to receive(:on?).with("push").and_return(true)
      allow(Push).to receive(:deliver)
      expect { Reliability::Watchdog.check! }.to change(Notification, :count).by(1)
      expect(Push).to have_received(:deliver).once
      expect(enqueued_jobs.select { |j| j["job_class"] == "SendPushJob" }).to be_empty
      expect { Reliability::Watchdog.check! }.not_to change(Notification, :count)
      expect(Health::Checks::Queues::DELAY_ERROR).to eq(5.minutes)
    end
  end
end
