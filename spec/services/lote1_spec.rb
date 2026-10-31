require "rails_helper"

# Lote 1 da paridade com o HA: canais e transportes plugáveis do aviso, Web
# Push, aviso com botões (evento, gatilho e espera), imagem e link,
# continue_on_error e o contrato "toda ação pode devolver dados".
RSpec.describe "Lote 1: avisos, push e respostas nas automações" do
  let(:tenant) { create(:tenant) }
  let(:owner) { create(:user, tenant: tenant, role: "owner", name: "Dona") }
  let(:member) { create(:user, tenant: tenant, role: "member", name: "Morador") }
  let(:site) { within(tenant) { create(:site, name: "Local") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Virtual", driver: "virtual") } }
  let(:lamp) { within(tenant) { create(:point, device: device, site: site, key: "sala.luz", name: "Luz", writable: true, value: false) } }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def build(definition, kind: "automation", mode: "single")
    a = Automation.create!(site: site, name: "Teste #{SecureRandom.hex(3)}", kind: kind, mode: mode)
    a.publish!(definition)
    a.update!(enabled: true) unless kind == "script"
    a
  end

  def vapid_env
    key = WebPush.generate_key
    { "VAPID_PUBLIC_KEY" => key.public_key, "VAPID_PRIVATE_KEY" => key.private_key }
  end

  # Inscrição com chaves de cliente válidas (a cifra do payload roda de verdade).
  def subscription(user, endpoint = "https://push.exemplo.com/sub/#{SecureRandom.hex(4)}")
    ec = OpenSSL::PKey::EC.generate("prime256v1")
    p256dh = Base64.urlsafe_encode64(ec.public_key.to_bn.to_s(2), padding: false)
    PushSubscription.create!(user: user, endpoint: endpoint, p256dh_key: p256dh, auth_key: Base64.urlsafe_encode64(SecureRandom.random_bytes(16), padding: false))
  end

  def with_env(vars)
    old = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  describe "canais e transportes plugáveis" do
    it "um canal novo registrado funciona sem mexer no Notifier, na ação Avisar nem no editor" do
      sent = []
      fake = Module.new do
        define_singleton_method(:owns?) { |c| c.start_with?("eco:") }
        define_singleton_method(:choices) { |_site| [ [ "eco:1", "Eco de teste" ] ] }
        define_singleton_method(:label) { |_c| "Eco de teste" }
        define_singleton_method(:capabilities) { %i[text] }
        define_singleton_method(:deliver) { |c, list| sent << [ c, list.map(&:title) ] }
      end
      stub_const("Notifier::Channels::Eco", fake)
      stub_const("Notifier::CHANNELS", Notifier::CHANNELS + %w[Eco])

      expect(Notifier.channel_choices(site)).to include([ "eco:1", "Eco de teste" ])
      expect(Notifier.valid_channels?([ "eco:1" ])).to be true
      a = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "notify", "channels" => [ "eco:1" ], "title" => "Oi {{ site.name }}" } ] })
      expect(a.fire!({ "type" => "manual" }).status).to eq("done")
      expect(sent).to eq([ [ "eco:1", [ "Oi Local" ] ] ])
      expect(Notifier.channel_label("nada")).to eq("Canal removido")
    end

    it "um transporte de push novo recebe a mensagem cortada pelo que ele suporta" do
      got = []
      fake = Module.new do
        define_singleton_method(:configured?) { true }
        define_singleton_method(:capabilities) { %i[text tag] }
        define_singleton_method(:deliver) { |user, message| got << [ user.id, message.to_h(capabilities) ] }
        define_singleton_method(:clear) { |user, tag| got << [ user.id, tag ] }
      end
      stub_const("Push::Pombo", fake)
      stub_const("Push::TRANSPORTS", %w[Pombo])
      owner
      n = Notifier.notify!(kind: "aviso", title: "T", body: "B", push: false,
                           data: { "tag" => "x", "actions" => [ { "id" => "ok", "title" => "Ok" } ], "url" => "/paineis", "image_url" => "https://img.exemplo.com/a.jpg" })
      SendPushJob.perform_now(n.id)
      msg = got.sole.last
      expect(msg).to include("title" => "T", "tag" => "x")
      expect(msg.keys).not_to include("actions", "image")
      expect(msg["data"]).to eq("id" => n.id, "url" => "/notificacoes")
      SendPushJob.perform_now(n.id, clear_tag: "x")
      expect(got.last).to eq([ owner.id, "x" ])
      expect(Notifier::Channels::Push.capabilities).to eq(%i[text tag])
    end

    it "Alexa fala só o texto, uma vez, e erro de comando não derruba o aviso" do
      echo = create(:point, device: create(:device, site: site, driver: "alexa", name: "Echo Sala"), capability: "speaker")
      allow(Points::Command).to receive(:call).and_raise(Points::Command::Error.new(:offline, "fora"))
      expect(Notifier.channel_label("alexa:#{echo.id}")).to eq("Falar na Echo Sala")
      expect(Notifier.channel_label("alexa:#{SecureRandom.uuid}")).to eq("Echo removida")
      expect(Notifier.deliver!([ "in_app", "alexa:#{echo.id}" ], kind: "aviso", title: "Oi")).to be_a(Notification)
      expect(Points::Command).to have_received(:call).once
    end
  end

  describe "destinatários" do
    it "administradores, uma pessoa ou um papel no local (uma notificação por pessoa)" do
      owner
      create(:site_membership, site: site, user: member, role: "resident")
      guest = create(:user, tenant: tenant, role: "member")
      create(:site_membership, site: site, user: guest, role: "guest")
      expect(Notifier.recipients("admins", site)).to eq([ nil ])
      expect(Notifier.recipients("user:#{member.id}", site)).to eq([ member ])
      expect(Notifier.recipients("role:resident", site)).to contain_exactly(owner, member)
      expect(Notifier.recipients("role:guest", site)).to contain_exactly(owner, member, guest)
      expect(Notifier.recipient_choices(site).map(&:last)).to include("admins", "role:guest", "user:#{member.id}")
      expect(Notifier.recipient_label("role:guest", site)).to eq("Todos do local")
      expect(Notifier.recipient_label("user:#{SecureRandom.uuid}", site)).to eq("pessoa removida")

      Notifier.deliver!([ "in_app" ], to: "role:resident", site: site, kind: "aviso", title: "Para moradores", dedup_key: "k")
      expect(Notification.where(title: "Para moradores").pluck(:user_id)).to contain_exactly(owner.id, member.id)
      expect(Notification.where(title: "Para moradores").pluck(:dedup_key)).to all(start_with("k:"))
    end

    it "tag igual substitui e \"só apagar\" marca como lido e pede aos canais" do
      first = Notifier.notify!(kind: "aviso", title: "1", data: { "tag" => "t" }, push: false)
      second = Notifier.notify!(kind: "aviso", title: "2", data: { "tag" => "t" }, push: false)
      expect(first.reload.read_at).to be_present
      expect(second.reload.read_at).to be_nil
      expect { Notifier.deliver!([ "push" ], clear: true, kind: "aviso", title: "x", data: { "tag" => "t" }) }.to have_enqueued_job(SendPushJob).with(second.id, clear_tag: "t")
      expect(second.reload.read_at).to be_present
      expect(Notifier.clear!([ nil ], "")).to be_nil
    end
  end

  describe "Web Push (transporte Browser)" do
    it "cifra e envia com VAPID, prioridade, tag e validade; inscrição morta sai" do
      with_env(vapid_env) do
        expect(Push.transports).to include(Push::Browser)
        sub = subscription(owner)
        dead = subscription(owner, "https://push.exemplo.com/morta")
        stub_request(:post, sub.endpoint).to_return(status: 201)
        stub_request(:post, dead.endpoint).to_return(status: 410)
        n = Notifier.notify!(kind: "aviso", title: "Alerta", push: false, data: { "priority" => "critical", "ttl" => 600, "group" => "g" })
        Push.deliver(n)
        expect(a_request(:post, sub.endpoint).with(headers: { "Ttl" => "600", "Urgency" => "high", "Content-Encoding" => "aes128gcm" })).to have_been_made
        expect(PushSubscription.exists?(dead.id)).to be false
        expect(sub.reload.last_used_at).to be_present

        msg = Push::Message.new(n, owner)
        expect(msg.to_h(Push::Browser.capabilities)).to include("tag" => "critico-#{n.id}", "requireInteraction" => true)
        expect(msg.to_h(Push::Browser.capabilities)["data"]).not_to include("group")
        expect(msg.to_h["data"]).to include("group" => "g", "priority" => "critical")

        stub_request(:post, sub.endpoint).to_raise(SocketError.new("sem rede"))
        Push::Browser.clear(owner, "x")
        expect(PushSubscription.exists?(sub.id)).to be true
      end
    end

    it "sem chaves VAPID o transporte fica desligado e o FCM leva a mesma mensagem" do
      with_env("VAPID_PUBLIC_KEY" => nil, "VAPID_PRIVATE_KEY" => nil, "FCM_CREDENTIALS_JSON" => "{}") do
        expect(Push.transports).to eq([ Push::Fcm ])
        owner.device_tokens.create!(token: "tok", platform: "android")
        owner.device_tokens.create!(token: "tok2", platform: "ios")
        allow(Push::FcmService).to receive_messages(deliver: true, deliver_data: :unregistered)
        n = Notifier.notify!(kind: "aviso", title: "Oi", push: false, data: { "actions" => [ { "id" => "a", "title" => "A" } ] })
        Push.deliver(n)
        # Android: só dados (o app monta a notificação com os botões); iOS: notificação do sistema.
        expect(Push::FcmService).to have_received(:deliver_data)
          .with("tok", data: hash_including("type" => "notification", "title" => "Oi", "actions" => anything, "token" => anything, "notification_id" => n.id))
        expect(Push::FcmService).to have_received(:deliver).with("tok2", hash_including(title: "Oi", data: hash_including("actions", "token", "notification_id" => n.id)))
        expect(owner.device_tokens.pluck(:token)).to eq([ "tok2" ])
        Push::Fcm.clear(owner, "t")
        expect(Push::FcmService).to have_received(:deliver_data).with("tok2", data: { "type" => "clear", "tag" => "t" })
      end
    end

    it "nome do aparelho pelo navegador" do
      expect(PushSubscription.guess_name("Mozilla/5.0 (Linux; Android 14) Chrome/130.0 Mobile Safari/537.36")).to eq("Chrome no Android")
      expect(PushSubscription.guess_name("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0) Safari/604.1")).to eq("Safari no iPhone")
      expect(PushSubscription.guess_name("")).to eq("Navegador")
      expect(PushSubscription.new(user: owner, endpoint: "http://x", p256dh_key: "a", auth_key: "b")).not_to be_valid
    end
  end

  describe "aviso com botões, imagem e link" do
    let(:buttons) { [ { "id" => "sim", "title" => "Sim" }, { "id" => "nao", "title" => "Não" } ] }

    it "a resposta vale uma vez, só com o token da pessoa, e dispara o gatilho Resposta de aviso" do
      owner
      reaction = build({ "triggers" => [ { "type" => "notification_action", "actions" => "sim" } ],
                         "actions" => [ { "type" => "notify", "channels" => [ "in_app" ], "title" => "{{ trigger.user }} disse {{ trigger.action }}" } ] })
      ask = build({ "triggers" => [ { "type" => "manual" } ],
                    "actions" => [ { "type" => "notify", "channels" => [ "in_app" ], "title" => "Pergunta", "buttons" => buttons, "url" => "/paineis",
                                     "image_url" => "https://img.exemplo.com/q.jpg", "tag" => "pergunta-{{ site.name }}", "priority" => "high",
                                     "ttl" => "1h", "sticky" => true, "group" => "casa" } ] })
      ask.fire!({ "type" => "manual" })
      n = Notification.find_by!(title: "Pergunta")
      expect(n.data).to include("tag" => "pergunta-Local", "ttl" => 3600, "sticky" => true, "priority" => "high", "url" => "/paineis")
      expect([ n.open_url, n.image_url, n.actionable? ]).to eq([ "/paineis", "https://img.exemplo.com/q.jpg", true ])

      token = n.action_token(owner)
      expect(Notification.from_action_token("lixo")).to be_nil
      expect(Notification.from_action_token(n.action_token(member))).to be_nil # não é dela (aviso dos administradores)
      found, user = Notification.from_action_token(token)
      expect([ found, user ]).to eq([ n, owner ])
      expect { n.respond!("talvez", owner) }.to raise_error(ArgumentError)
      expect(n.respond!("sim", owner)).to be true
      expect(n.respond!("nao", owner)).to be false
      expect(n.reload).to have_attributes(actionable?: false, response_title: "Sim")
      expect(reaction.runs.sole.status).to eq("done")
      expect(Notification.find_by(title: "Dona disse sim")).to be_present
    end

    it "quadro da câmera capturado agora e guardado com validade; câmera fora do ar manda sem imagem" do
      cam = create(:point, device: create(:device, site: site, driver: "go2rtc"), key: "entrada.camera", capability: "stream", name: "Entrada")
      allow(Drivers::Go2rtc).to receive(:snapshot).and_return("\xFF\xD8jpeg".b)
      a = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "notify", "channels" => [ "in_app" ], "title" => "Movimento", "camera" => "entrada.camera" } ] })
      expect(a.definition.dig("actions", 0, "camera")).to eq(cam.id)
      run = a.fire!({ "type" => "manual" })
      n = Notification.find_by!(title: "Movimento")
      expect(n.image).to be_attached
      expect(n.image_url).to start_with("/push/imagem?t=")
      expect(run.steps.last["detail"]).to include("com quadro de Entrada")

      travel(Notification::IMAGE_TTL + 1.day) { Notification.purge_old_images! }
      expect(n.reload.image).not_to be_attached

      allow(Drivers::Go2rtc).to receive(:snapshot).and_raise(Drivers::Go2rtc::Error, "Câmera sem conexão.")
      run = a.fire!({ "type" => "manual" })
      expect(run.steps.last["detail"]).to include("sem imagem: Câmera sem conexão.")
    end

    it "valida botões, câmera, destinatário e o apagar sem tag" do
      other = create(:point, device: device, key: "sala.outro", capability: "onoff")
      bad = { "triggers" => [ { "type" => "manual" } ],
              "actions" => [ { "type" => "notify", "title" => "x", "buttons" => [ { "id" => "A B", "title" => "" } ] * 4, "camera" => other.id, "to" => "user:#{SecureRandom.uuid}" },
                             { "type" => "notify", "title" => "y", "clear" => true, "to" => "todos" } ] }
      errors = Automations::Dsl.errors(Automations::Dsl.normalize(bad, site), site).join(" | ")
      expect(errors).to include("botões: até 3", "não é câmera", "pessoa não existe", "para apagar, informe a tag", "destinatário inválido")
      dup = { "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "notify", "title" => "x", "buttons" => [ { "id" => "a", "title" => "A" } ] * 2 } ] }
      expect(Automations::Dsl.errors(dup, site).join).to include("id repetido")
    end

    it "simulação não envia nem apaga" do
      a = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "notify", "title" => "x", "tag" => "t", "clear" => true },
                                                                           { "type" => "notify", "title" => "y", "buttons" => buttons } ] })
      run = a.simulate!
      expect(run.steps.pluck("result")).to include("simulated")
      expect(run.steps.map { |s| s["title"] }).to include("Apagar aviso t", "Avisar: y")
      expect(Notification.count).to eq(0)
    end
  end

  describe "esperar resposta do aviso" do
    let(:definition) do
      { "triggers" => [ { "type" => "manual" } ],
        "actions" => [ { "type" => "notify", "channels" => [ "in_app" ], "title" => "Confirma?", "buttons" => [ { "id" => "ok", "title" => "Ok" }, { "id" => "nao", "title" => "Não" } ] },
                       { "type" => "wait_notification", "actions" => "ok", "timeout" => "5m", "response_variable" => "resposta" },
                       { "type" => "set", "var" => "quem", "value" => "{{ resposta.user }}:{{ resposta.action }}" } ] }
    end

    it "segue com a resposta (só a do botão filtrado, só deste aviso)" do
      a = build(definition)
      run = a.fire!({ "type" => "manual" })
      expect(run.status).to eq("waiting")
      n = Notification.find_by!(title: "Confirma?")
      other = Notifier.notify!(kind: "aviso", title: "Outro", push: false, data: { "actions" => [ { "id" => "ok", "title" => "Ok" } ], "site_id" => site.id, "run_id" => SecureRandom.uuid })
      other.respond!("ok", owner)
      expect(run.reload.status).to eq("waiting")
      n.respond!("ok", owner)
      expect(run.reload.status).to eq("done")
      expect(run.state["vars"]["quem"]).to eq("Dona:ok")
      expect(run.steps.pluck("title")).to include("Resposta recebida")
    end

    it "no tempo limite segue com a variável vazia" do
      run = build(definition).fire!({ "type" => "manual" })
      travel(6.minutes) { perform_enqueued_jobs(at: Time.current) }
      expect(run.reload.status).to eq("done")
      expect(run.state["vars"]).to include("resposta" => nil, "quem" => ":")
    end

    it "sem seguir no tempo limite, para; na simulação ninguém responde" do
      defn = definition.deep_dup
      defn["actions"][1]["continue_on_timeout"] = false
      a = build(defn)
      run = a.fire!({ "type" => "manual" })
      travel(6.minutes) { perform_enqueued_jobs(at: Time.current) }
      expect(run.reload).to have_attributes(status: "stopped", error: "Tempo limite da espera")
      sim = a.simulate!
      expect(sim.steps.map { |s| s["result"] }).to include("simulated")
    end
  end

  describe "continue_on_error" do
    it "falha tolerada fica no trace e a execução segue; sem a flag, para" do
      stub_request(:post, "https://api.exemplo.com/x").to_return(status: 500)
      actions = [ { "type" => "http", "method" => "POST", "url" => "https://api.exemplo.com/x", "continue_on_error" => true },
                  { "type" => "set", "var" => "depois", "expr" => "1" } ]
      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => actions }).fire!({ "type" => "manual" })
      expect(run.status).to eq("done")
      step = run.steps.find { |s| s["result"] == "tolerated" }
      expect(step).to include("title" => "Chamar HTTP / webhook: erro tolerado", "detail" => "api.exemplo.com respondeu 500.")
      expect(run.state["vars"]["depois"]).to eq(1)

      actions[0]["continue_on_error"] = false
      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => actions }).fire!({ "type" => "manual" })
      expect(run.status).to eq("failed")
    end

    it "erro interno tolerado é reportado; ações de controle não têm a flag" do
      allow(Points::Command).to receive(:call).and_raise(RuntimeError, "boom")
      allow(Rails.error).to receive(:report)
      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "command", "point" => lamp.id, "command" => "on", "continue_on_error" => true } ] })
            .fire!({ "type" => "manual" })
      expect(run.status).to eq("done")
      expect(Rails.error).to have_received(:report)
      expect(Automations::ActionTypes["wait"].fields.map(&:name)).not_to include("continue_on_error")
      expect(Automations::ActionTypes["command"].fields.map(&:name)).to include("continue_on_error")
    end
  end

  describe "ações que devolvem dados (response_variable)" do
    it "é um contrato de plugin: quem declara `returns` ganha o campo" do
      with_return = Automations::ActionTypes.plugins.select(&:returns).map(&:key)
      expect(with_return).to include("script", "http", "calendar_events", "wait_notification")
      expect(Automations::ActionTypes["command"].fields.map(&:name)).not_to include("response_variable")
      expect(Automations::ActionTypes["http"].fields.map(&:name)).to include("response_variable")
    end

    it "HTTP guarda status, corpo e JSON" do
      stub_request(:get, "https://api.exemplo.com/j").to_return(body: { "temp" => 21 }.to_json)
      actions = [ { "type" => "http", "method" => "GET", "url" => "https://api.exemplo.com/j", "response_variable" => "r" },
                  { "type" => "set", "var" => "dobro", "expr" => "r.json.temp * 2" },
                  { "type" => "set", "var" => "texto", "value" => "{{ r.status }}/{{ r.json.temp }}" } ]
      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => actions }).fire!({ "type" => "manual" })
      expect(run.state["vars"]).to include("dobro" => 42, "texto" => "200/21")
      stub_request(:get, "https://api.exemplo.com/j").to_return(body: "[quebrado")
      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => actions.first(1) }).fire!({ "type" => "manual" })
      expect(run.state.dig("vars", "r")).to eq("status" => 200, "body" => "[quebrado")
    end

    it "variável sem o campo vira erro legível; lista tem count" do
      ctx = Automations::Context.new(site: site, vars: { "a" => { "l" => [ 1, 2 ] } })
      expect(ctx.calc("a.l.count + a.l.0")).to eq(3)
      expect { ctx.calc("a.x + 1") }.to raise_error(Automations::Context::Error, /a.x/)
    end

    it "Ler eventos da agenda num intervalo, com filtro" do
      travel_to Time.zone.parse("2026-11-02 08:00")
      agenda = create(:point, device: device, key: "agenda.familia", capability: "calendar", name: "Família",
                              address: { "events" => [ { "summary" => "Reunião", "start" => "2026-11-02T10:00:00-03:00", "end" => "2026-11-02T11:00:00-03:00" },
                                                       { "summary" => "Aniversário", "start" => "2026-11-02T00:00:00-03:00", "end" => "2026-11-03T00:00:00-03:00", "all_day" => true },
                                                       { "summary" => "Reunião", "start" => "2026-11-05T10:00:00-03:00", "end" => "2026-11-05T11:00:00-03:00" } ] })
      actions = [ { "type" => "calendar_events", "point" => agenda.id, "within" => "24h", "response_variable" => "agenda" },
                  { "type" => "if", "conditions" => [ { "type" => "expr", "expr" => "agenda.count > 1" } ],
                    "then" => [ { "type" => "set", "var" => "resumo", "value" => "{% for e in agenda.events %}{{ e.summary }};{% endfor %}" } ] },
                  { "type" => "calendar_events", "point" => agenda.id, "start" => "1h", "within" => "168h", "contains" => "reun", "response_variable" => "reunioes" } ]
      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => actions }).fire!({ "type" => "manual" })
      expect(run.status).to eq("done")
      expect(run.state["vars"]["resumo"]).to eq("Reunião;Aniversário;")
      expect(run.state["vars"]["reunioes"]).to include("count" => 2, "titles" => "Reunião, Reunião")

      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "calendar_events", "point" => lamp.id, "within" => "1h" } ] }).fire!({ "type" => "manual" })
      expect(run.error).to eq("Luz não é uma agenda.")
    end

    it "Executar script e esperar a resposta (na hora e quando o script espera); sem esperar, dispara e segue" do
      quick = build({ "actions" => [ { "type" => "set", "var" => "valor", "expr" => "7" } ] }, kind: "script")
      slow = build({ "actions" => [ { "type" => "wait", "for" => "1m" }, { "type" => "set", "var" => "valor", "expr" => "9" } ] }, kind: "script")
      broken = build({ "actions" => [ { "type" => "wait", "for" => "1m" }, { "type" => "stop", "reason" => "deu ruim", "error" => true } ] }, kind: "script")
      call = ->(script, extra = {}) { { "type" => "script", "script" => script.id, "wait" => true, "response_variable" => "res" }.merge(extra) }

      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ call.(quick), { "type" => "set", "var" => "x", "expr" => "res.valor + 1" } ] }).fire!({ "type" => "manual" })
      expect(run.state["vars"]["x"]).to eq(8)

      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ call.(slow), { "type" => "set", "var" => "x", "expr" => "res.valor + 1" } ] }).fire!({ "type" => "manual" })
      expect(run.status).to eq("waiting")
      travel(2.minutes) { perform_enqueued_jobs(at: Time.current) }
      expect(run.reload.status).to eq("done")
      expect(run.state["vars"]["x"]).to eq(10)
      expect(run.steps.pluck("title")).to include("Script #{slow.name} terminou")

      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ call.(broken) ] }).fire!({ "type" => "manual" })
      travel(2.minutes) { perform_enqueued_jobs(at: Time.current) }
      expect(run.reload).to have_attributes(status: "failed", error: "deu ruim")

      run = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "script", "script" => slow.id } ] }).fire!({ "type" => "manual" })
      expect(run.status).to eq("done")

      bad = { "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "script", "script" => quick.id, "response_variable" => "r" } ] }
      expect(Automations::Dsl.errors(bad, site).join).to include("marque esperar o fim")
    end
  end
end
