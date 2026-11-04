require "rails_helper"

# ondaB1: paridade com o HA no grupo 3 (voz/Assist). Cada pacote numa seção.
# Nada de rede nem aparelho real: pontos em aparelho virtual, IA e voz por
# plugin falso (stub_const), Wyoming contra servidor falso local.
RSpec.describe "ondaB1: paridade HA (voz e Assist)" do
  let(:tenant) { create(:tenant) }
  let(:owner) { create(:user, tenant: tenant, role: "owner") }
  let(:site) { create(:site) }
  let(:sala) { create(:area, site: site, name: "Sala", aliases: [ "living room" ]) }
  let(:quarto) { create(:area, site: site, name: "Quarto", aliases: [ "bedroom" ]) }
  let(:lampada) { create(:device, site: site, area: sala, name: "Lâmpada") }
  let!(:luz) { create(:point, site: site, device: lampada, name: "Luz", value: false, aliases: [ "light" ]) }
  let!(:brilho) { create(:point, site: site, device: lampada, name: "Brilho", capability: "dimmer", value: 40) }
  let!(:cor) { create(:point, site: site, device: lampada, name: "Cor", capability: "color", value: nil) }
  let!(:luz_quarto) { create(:point, site: site, device: create(:device, site: site, area: quarto, name: "Abajur"), name: "Luz", value: false) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def say(text, user: owner, **opts) = Assist.call(site: site, user: user, text: text, **opts)

  describe "B1 intenções nativas (plugins)" do
    it "frase-modelo do HA: [opcional], (a|b), {slot}, palavra inteira e número" do
      s = Assist::Sentences
      expect(s.match("(ligar|ligue) [a|o] {name}", "ligue a luz da sala")).to eq("name" => "luz da sala")
      expect(s.match("ligar [o] {name}", "ligar oficina")).to eq("name" => "oficina")
      expect(s.match("{name} em {b} [%]", "luz em 50", numbers: %w[b])).to eq("name" => "luz", "b" => "50")
      expect(s.match("{name} em {b}", "luz em cinquenta", numbers: %w[b])).to be_nil
      expect(s.match("que horas (sao|e)", "que horas sao")).to eq({})
      expect(s.error("ligar [a {name}")).to be_present
      expect(s.error("ligar [a] {name}")).to be_nil
      expect(Assist.normalize("Coloque 22,5 graus!")).to eq("coloque 22.5 graus")
      expect([ Assist.seconds("1 hora e 30 minutos"), Assist.seconds("meia hora"), Assist.seconds("dez segundos"), Assist.seconds("5 minutes") ]).to eq([ 5400, 1800, 10, 300 ])
    end

    it "brilho, cor, mais claro e o ponto irmão do mesmo aparelho" do
      expect(say("deixe a luz da sala em 70%")).to include("intent" => "light_brightness", "text" => "Brilho de Lâmpada em 70%.")
      expect(brilho.reload.value).to eq(70)
      say("diminua a luz da sala")
      expect(brilho.reload.value).to eq(45)
      expect(say("mude a luz da sala para azul")["intent"]).to eq("light_color")
      expect(cor.reload.value).to include("mode" => "hs")
      say("deixe a luz da sala de branco quente")
      expect(cor.reload.value).to include("mode" => "temp", "kelvin" => 2700)
      expect(say("mude a luz da sala para xadrez")["intent"]).not_to eq("light_color")
    end

    it "clima, cortina, mídia e robô" do
      ar = create(:point, site: site, device: create(:device, site: site, area: sala, name: "Ar"), name: "Alvo", capability: "setpoint", unit: "°C", min: 16, max: 30, value: 24)
      create(:point, site: site, device: create(:device, site: site, area: sala, name: "Sensor"), name: "Temperatura", capability: "measure", unit: "°C", value: 26.5, quality: "good")
      cortina = create(:point, site: site, device: create(:device, site: site, area: sala, name: "Cortina"), name: "Cortina", capability: "setpoint", device_class: "curtain", unit: "%", min: 0, max: 100, value: 0)
      tv = create(:point, site: site, device: create(:device, site: site, area: sala, name: "TV"), name: "TV", capability: "media", value: { "state" => "playing" })
      robo = create(:point, site: site, device: create(:device, site: site, name: "Robô"), name: "Robô", capability: "vacuum", value: "docked")

      expect(say("coloque o ar em 22 graus")).to include("intent" => "climate_set_temperature", "text" => "Ar em 22 °C.")
      expect(ar.reload.value).to eq(22.0)
      expect(say("qual a temperatura")["text"]).to eq("Está 26,5 °C.")
      expect(say("abra a cortina")["text"]).to eq("Abri Cortina.")
      expect(cortina.reload.value).to eq(100.0)
      expect(say("deixe a cortina em 30%")["text"]).to eq("Cortina em 30%.")
      expect(say("pausa")).to include("intent" => "media_pause", "points" => [ tv.id ])
      expect(say("volume da tv em 20")["text"]).to eq("Volume de TV em 20.")
      expect(say("toque Beatles na TV")["text"]).to eq("Tocando beatles em TV.")
      expect(say("próxima música")["intent"]).to eq("media_next")
      expect(say("começar a limpeza")["text"]).to eq("Comecei a limpeza com Robô.")
      expect(say("mande o robô voltar para a base")["intent"]).to eq("vacuum_dock")
      expect(Command.where(point: robo).order(:created_at, :id).pluck(:command)).to eq(%w[start home])
    end

    it "timers: cria, diz quanto falta, pausa, continua, cancela e o fim vira evento" do
      expect(say("timer de 5 minutos para o bolo")["text"]).to eq("Timer bolo de 5 minutos iniciado.")
      timer = AssistTimer.last
      expect(timer).to have_attributes(name: "bolo", duration_s: 300, status: "active")
      expect(say("quanto falta no timer")["text"]).to match(/bolo: faltam (4 minutos e \d+ segundos|5 minutos)\./)
      expect(say("pausar o timer")["text"]).to eq("Pausei 1 timer.")
      expect(timer.reload.status).to eq("paused")
      expect(say("continuar o timer")["text"]).to eq("Continuei 1 timer.")
      stamp = timer.reload.ends_at.iso8601(3)
      expect(Automations::Triggers).to receive(:event).with(site.id, "assist_timer_finished", hash_including("name" => "bolo"))
      AssistTimerJob.perform_now(timer.id, "velho")
      expect(timer.reload.status).to eq("active")
      AssistTimerJob.perform_now(timer.id, stamp)
      expect(timer.reload.status).to eq("finished")
      say("timer de 10 segundos")
      expect(say("cancelar o timer")["text"]).to eq("Cancelei 1 timer.")
      expect(say("cancelar o timer")["text"]).to eq("Nenhum timer ativo.")
    end

    it "listas: adiciona, marca e lê; estado sim/não, quais e quantos; hora, data e tempo" do
      HelperTypes.save(HelperTypes.build(site, HelperTypes::TodoList), "name" => "Lista de compras")
      say("adicione leite à lista de compras")
      say("coloca pão na lista de compras")
      expect(say("risque leite da lista de compras")["text"]).to eq("Marquei leite em Lista de compras.")
      expect(say("o que tem na lista de compras")["text"]).to eq("Em Lista de compras: pão.")

      luz.update!(value: true)
      expect(say("a luz da sala está ligada")["text"]).to start_with("Sim.")
      expect(say("a luz do quarto está ligada")["text"]).to start_with("Não.")
      expect(say("quais luzes estão ligadas")["text"]).to eq("Luz Lâmpada.")
      expect(say("quantas luzes estão desligadas")["text"]).to eq("1: Luz Abajur.")
      travel_to(Time.zone.parse("2026-11-02 14:05")) do
        expect(say("que horas são")["text"]).to eq("São 14:05.")
        expect(say("que dia é hoje")["text"]).to include("novembro")
      end
      create(:point, site: site, device: create(:device, site: site, name: "Previsão"), name: "Previsão", capability: "weather", value: "sunny", quality: "good")
      expect(say("como está o tempo")["intent"]).to eq("get_weather")
      expect(say("deixa pra lá")).to include("intent" => "nevermind", "text" => "")
    end

    it "cena, script, anúncio e segurança: crítico nunca, convidado só o normal" do
      site.scenes.create!(name: "Cinema", items: [ { "point_id" => luz.id, "command" => "on" } ])
      expect(say("ligar cinema")["text"]).to eq("Cena Cinema acionada.")
      echo = create(:point, site: site, device: create(:device, site: site, name: "Echo"), name: "Echo", capability: "speaker", value: {})
      expect(say("anuncie que o jantar está pronto")["text"]).to eq("Anunciei em Echo.")
      expect(Command.where(point: echo).last.value).to eq("o jantar está pronto")
      portao = create(:point, site: site, device: create(:device, site: site, name: "Garagem"), name: "Portão", capability: "gate", device_class: "gate", risk: "critical", value: "closed")
      expect(say("abra o portão")["text"]).to eq("Por voz não posso comandar Portão.")
      expect(Command.where(point: portao)).to be_empty

      guest = create(:user, tenant: tenant, role: "member")
      create(:site_membership, site: site, user: guest, role: "guest")
      brilho.update!(risk: "sensitive")
      expect(say("deixe a luz da sala em 10%", user: guest)["text"]).to include("não posso comandar Lâmpada")
    end

    it "satélite numa área: \"acenda a luz\" sem dizer o cômodo" do
      r = say("acenda a luz", area: quarto)
      expect(r["points"]).to eq([ luz_quarto.id ])
      expect([ luz.reload.value, luz_quarto.reload.value ]).to eq([ false, true ])
    end

    it "uma intenção nova entra pelo registro, nos três idiomas e como ferramenta, sem mudar o núcleo" do
      fake = Class.new(Assist::Intent) do
        describe key: "teste_bom_dia", slots: %w[nome], description: "Cumprimenta",
                 sentences: { "pt-BR" => [ "bom dia [{nome}]" ], "en" => [ "good morning [{nome}]" ], "es" => [ "buenos dias [{nome}]" ] }
        texts en: { description: "Greets", oi: "Good morning %{n}!" }, es: { description: "Saluda", oi: "¡Buenos días %{n}!" }, "pt-BR" => { oi: "Bom dia %{n}!" }
        def self.handle(_ctx, slots) = reply(text(:oi, n: slots["nome"].to_s))
      end
      stub_const("Assist::Intents::TesteBomDia", fake)
      stub_const("Assist::INTENTS", %w[TesteBomDia] + Assist::INTENTS)
      expect(say("Bom dia, Ana!")).to include("intent" => "teste_bom_dia", "text" => "Bom dia ana!", "slots" => { "nome" => "ana" })
      expect(say("good morning", language: "en")["text"]).to eq("Good morning !")
      expect(say("buenos días", language: "es-ES")["text"]).to eq("¡Buenos días !")
      expect(fake.tool).to include(name: "teste_bom_dia", description: "Cumprimenta")
      expect(Assist.understand(site, "bom dia Rui")).to eq([ fake, { "nome" => "rui" } ])
    end
  end

  describe "B2 frases personalizadas e gatilho por frase" do
    def auto(trigger, actions: [ { "type" => "command", "point" => luz.id, "command" => "on" } ])
      a = site.automations.create!(name: "Teste frase #{SecureRandom.hex(3)}")
      a.publish!({ "triggers" => [ trigger ], "actions" => actions })
      a.update!(enabled: true)
      a
    end

    it "frase do usuário com {slot} dispara a automação antes das nativas e responde com o slot" do
      a = auto({ "type" => "conversation", "command" => "(boa noite|hora de dormir) [{quem}]
modo festa", "response" => "Boa noite, {quem}!" })
      r = say("Boa noite, Ana")
      expect(r).to include("intent" => "conversation", "text" => "Boa noite, ana!", "slots" => { "quem" => "ana" })
      run = a.runs.order(:created_at).last
      expect(run.trigger).to include("type" => "conversation", "sentence" => "Boa noite, Ana", "slots" => { "quem" => "ana" })
      expect(luz.reload.value).to be true
      expect(say("modo festa")["text"]).to eq("Boa noite, !")
      a.update!(enabled: false)
      expect(say("modo festa")["intent"]).not_to eq("conversation")
    end

    it "valida a frase no editor e recusa por voz o que comanda crítico" do
      plugin = Automations::TriggerTypes::ConversationTrigger
      expect(plugin.rules({ "command" => "ligar [a {x}" })).to eq([ "frase 1: Colchetes ou parênteses sem par." ])
      expect(plugin.rules({ "command" => "" })).to be_present
      expect(plugin.title({ "command" => "abrir tudo" })).to eq("Frase \"abrir tudo\"")
      portao = create(:point, site: site, device: create(:device, site: site, name: "Garagem"), name: "Portão", risk: "critical", value: false)
      auto({ "type" => "conversation", "command" => "abre te sesamo" }, actions: [ { "type" => "command", "point" => portao.id, "command" => "on" } ])
      expect(say("abre-te sésamo")["text"]).to eq("Por voz não posso rodar #{Automation.last.name}.")
      expect(portao.reload.value).to be false
    end
  end

  describe "B4 IA com ferramentas (papel x risco)" do
    # Provedor falso: responde em sequência o que a lista manda e guarda o que viu.
    def fake_llm!(*answers)
      seen = []
      klass = Class.new(Ai::Providers::Base) do
        describe key: "teste_llm", label: "Teste IA", default_model: "t-1", capabilities: %i[text structured], key_required: false
        texts en: { label: "Test AI" }, es: { label: "IA de prueba" }
        define_method(:complete) do |system:, user:, schema:, **|
          seen << { system: system, user: user, schema: schema }
          Ai::Providers::Base::Result.new(data: answers.shift || { "say" => "fim", "calls" => [] }, usage: { input: 1, output: 1 })
        end
      end
      stub_const("Ai::Providers::TesteLlm", klass)
      stub_const("Ai::PROVIDERS", Ai::PROVIDERS + %w[TesteLlm])
      AiAccount.create!(provider: "teste_llm")
      seen
    end

    it "chama a intenção como ferramenta, devolve o resultado ao modelo e responde; vê só o exposto" do
      luz_quarto.update!(expose: { "assist" => false })
      seen = fake_llm!({ "say" => "", "calls" => [ { "tool" => "turn_on", "args" => { name: "luz da sala" }.to_json } ] },
                       { "say" => "Pronto, acendi a sala.", "calls" => [] })
      r = say("deixa a sala clarinha", agent: "local_llm")
      expect(r).to include("intent" => "llm", "text" => "Pronto, acendi a sala.", "points" => [ luz.id ])
      expect(r["conversation_id"]).to be_present
      expect(luz.reload.value).to be true
      expect(seen.first[:system]).to include("turn_on(name, area)", "Luz Lâmpada (Sala)")
      expect(seen.first[:system]).not_to include("Abajur")
      expect(seen.last[:user]).to include("Ferramenta turn_on", "Liguei Luz.")
      expect(Command.last).to have_attributes(source: "voice", user_id: owner.id)
      expect(AiCall.where(source: "voz", provider: "teste_llm").count).to eq(2)
    end

    it "convidado: a ferramenta recusa o sensível e o crítico; sem IA, cai no não entendi" do
      guest = create(:user, tenant: tenant, role: "member")
      create(:site_membership, site: site, user: guest, role: "guest")
      luz.update!(risk: "sensitive")
      seen = fake_llm!({ "say" => "", "calls" => [ { "tool" => "turn_on", "args" => '{"name":"luz da sala"}' }, { "tool" => "rm_rf", "args" => "{}" } ] },
                       { "say" => "Não tenho permissão.", "calls" => [] })
      expect(say("acende a sala", user: guest, agent: "llm")["text"]).to eq("Não tenho permissão.")
      expect(luz.reload.value).to be false
      expect(seen.last[:user]).to include("Por voz não posso comandar Luz.", "ferramenta desconhecida")
      AiAccount.delete_all
      expect(say("acende a sala", agent: "llm")["intent"]).to eq("unknown")
    end
  end

  describe "B5 pipelines e depuração" do
    # Motor de voz falso (STT e TTS), registrado sem mudar o núcleo.
    def fake_engine!
      klass = Class.new(Assist::Engines::Base) do
        describe key: "teste_voz", label: "Voz de teste", kinds: %i[stt tts], fields: [ [ "voice", :text ] ]
        texts en: { label: "Test voice" }, es: { label: "Voz de prueba" }
        def self.check(cfg, _kind) = cfg["voice"] == "ruim" ? [ "voz ruim" ] : []
        def self.transcribe(_cfg, audio:, language:, **) = "#{audio} #{language == 'en' ? 'living room' : 'sala'}"
        def self.speak(cfg, text:, **) = { data: "#{cfg['voice']}:#{text}", media_type: "audio/wav" }
      end
      stub_const("Assist::Engines::TesteVoz", klass)
      stub_const("Assist::Engines::PLUGINS", Assist::Engines::PLUGINS + %w[TesteVoz])
      klass
    end

    it "STT → intenção → TTS pelo motor do pipeline, com cada etapa registrada" do
      fake_engine!
      pl = AssistPipeline.create!(site: site, name: "Teste casa", stt: { "engine" => "teste_voz" }, tts: { "engine" => "teste_voz", "voice" => "ana" }, preferred: true)
      out = Assist::Pipeline.run(site: site, user: owner, audio: "ligar a luz da", media_type: "audio/wav", speak: true, keep_audio: true)
      expect(out).to include("heard" => "ligar a luz da sala", "text" => "Liguei Luz.")
      expect(out["audio"][:data]).to eq("ana:Liguei Luz.")
      expect(out["audio_url"]).to include("/rails/active_storage/")
      run = AssistRun.find(out["run_id"])
      expect(run).to have_attributes(pipeline: pl, source: "web", heard: "ligar a luz da sala", intent: "turn_on", reply: "Liguei Luz.", error: nil)
      expect(run.stages.pluck("stage")).to eq(%w[stt intent tts])
      expect(run.stages.first).to include("engine" => "teste_voz", "text" => "ligar a luz da sala")
      expect(run.stages.all? { |st| st["ms"].is_a?(Integer) }).to be true
    end

    it "idioma e agente do pipeline; preferido único; motor desconhecido ou mal configurado não salva; erro fica no registro" do
      fake_engine!
      en = AssistPipeline.create!(site: site, name: "Teste en", language: "en", stt: { "engine" => "teste_voz" }, preferred: true)
      AssistPipeline.create!(site: site, name: "Teste pt", preferred: true)
      expect(en.reload.preferred).to be false
      expect(Assist::Pipeline.run(site: site, user: owner, audio: "turn on the light in the", pipeline: en)["text"]).to eq("Turned on Luz.")
      expect(AssistPipeline.new(site: site, name: "x", stt: { "engine" => "nada" })).not_to be_valid
      expect(AssistPipeline.new(site: site, name: "y", tts: { "engine" => "teste_voz", "voice" => "ruim" }).tap(&:valid?).errors[:tts]).to include("voz ruim")
      expect { Assist::Pipeline.run(site: site, user: owner, text: " ") }.to raise_error(ArgumentError)
      expect(AssistRun.order(:created_at).last.error).to eq("Fale ou escreva o que quer.")
    end

    it "guarda só as últimas execuções do local" do
      stub_const("AssistRun::KEEP", 2)
      3.times { |i| Assist::Pipeline.run(site: site, user: owner, text: "que horas são #{i}") }
      expect(AssistRun.where(site: site).count).to eq(2)
    end
  end

  describe "B6 Wyoming, palavra de ativação e satélites" do
    # Servidor Wyoming falso (Whisper + Piper + openWakeWord) em 127.0.0.1, sem rede de verdade.
    def fake_wyoming(text: "ligar a luz da sala")
      seen = Queue.new
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        loop do
          sock = server.accept
          c = Wyoming::Connection.new(sock, 5)
          type, data = c.read
          seen << [ type, data ]
          case type
          when "describe" then c.write("info", { "asr" => [ { "name" => "teste-whisper" } ], "satellite" => { "name" => "Teste sat" } })
          when "transcribe"
            loop { t, = c.read; break if t.nil? || t == "audio-stop" }
            c.write("transcript", { "text" => text })
          when "synthesize"
            c.write("audio-start", { "rate" => 16_000, "width" => 2, "channels" => 1 })
            c.write("audio-chunk", { "rate" => 16_000 }, "\x01\x00".b * 3000)
            c.write("audio-stop")
          when "detect"
            loop { t, = c.read; break if t.nil? || t == "audio-stop" }
            c.write("detection", { "name" => "ok_nabu" })
          end
          sock.close
        end
      rescue IOError, Errno::EBADF
        nil
      end
      yield server.addr[1], seen
    ensure
      thread&.kill
      server&.close
    end

    def wav(seconds = 0.5, amp = 3000) = Wyoming.wav(([ amp, -amp ].pack("s<s<") * (8000 * seconds)).b, 16_000, 2, 1)

    it "cliente Wyoming: describe, STT, TTS e detecção; WAV lido e escrito; erro claro sem WAV" do
      fake_wyoming do |port, seen|
        expect(Wyoming.describe("127.0.0.1", port)["asr"].first["name"]).to eq("teste-whisper")
        pcm, rate, width, channels = Wyoming.pcm_of(wav)
        expect([ rate, width, channels, pcm.bytesize ]).to eq([ 16_000, 2, 1, 16_000 ])
        expect(Wyoming.transcribe("127.0.0.1", port, pcm, language: "pt-BR")).to eq("ligar a luz da sala")
        voice = Wyoming.synthesize("127.0.0.1", port, "Oi", voice: "pt_BR-faber-medium")
        expect(voice).to include(media_type: "audio/wav", rate: 16_000)
        expect(Wyoming.pcm_of(voice[:data]).first.bytesize).to eq(6000)
        expect(Wyoming.detect("127.0.0.1", port, pcm, names: %w[ok_nabu])).to eq("ok_nabu")
        types = Array.new(seen.size) { seen.pop }.to_h
        expect(types["transcribe"]).to eq("language" => "pt")
        expect(types["synthesize"]).to eq("text" => "Oi", "voice" => { "name" => "pt_BR-faber-medium" })
      end
      expect { Wyoming.pcm_of("webm") }.to raise_error(Wyoming::Error, /WAV/)
      expect { Wyoming.describe("127.0.0.1", 1, timeout: 1) }.to raise_error(Wyoming::Error)
    end

    it "pipeline com motor Wyoming no STT e no TTS; configuração validada" do
      fake_wyoming do |port|
        cfg = { "engine" => "wyoming", "host" => "127.0.0.1", "port" => port.to_s }
        pl = AssistPipeline.create!(site: site, name: "Teste local", stt: cfg, tts: cfg.merge("voice" => "faber"))
        out = Assist::Pipeline.run(site: site, user: owner, audio: wav, media_type: "audio/wav", speak: true, pipeline: pl, keep_audio: true)
        expect(out).to include("heard" => "ligar a luz da sala", "text" => "Liguei Luz.")
        expect(out["audio"][:media_type]).to eq("audio/wav")
        expect(AssistRun.last.stages.pluck("engine")).to eq([ "wyoming", nil, "wyoming" ])
      end
      expect(AssistPipeline.new(site: site, name: "x", stt: { "engine" => "wyoming", "host" => "a b", "port" => "99999" }).tap(&:valid?).errors[:stt].size).to eq(2)
    end

    it "satélite Wyoming: run-pipeline → áudio → VAD → transcript, synthesize e a fala; área e papel do satélite" do
      brilho.update!(risk: "sensitive")
      fake_wyoming(text: "acenda a luz") do |port|
        cfg = { "engine" => "wyoming", "host" => "127.0.0.1", "port" => port.to_s }
        pl = AssistPipeline.create!(site: site, name: "Teste sat", stt: cfg, tts: cfg)
        server = TCPServer.new("127.0.0.1", 0)
        sat = AssistSatellite.create!(site: site, name: "Teste quarto", kind: "wyoming", host: "127.0.0.1", port: server.addr[1], area: quarto, pipeline: pl, role: "guest")
        got = []
        t = Thread.new do
          c = Wyoming::Connection.new(server.accept, 5)
          c.read && c.write("info", { "satellite" => { "name" => "Teste" } })
          c.read # run-satellite
          c.write("run-pipeline", { "start_stage" => "asr", "end_stage" => "tts" })
          c.write("audio-start", { "rate" => 16_000, "width" => 2, "channels" => 1 })
          c.write("audio-chunk", { "rate" => 16_000 }, Wyoming.pcm_of(wav(0.4)).first)
          c.write("audio-chunk", { "rate" => 16_000 }, Wyoming.pcm_of(wav(1.0, 0)).first)
          while (ev = c.read(3))
            got << ev.first
          end
        end
        Assist::Satellites::WyomingSatellite.serve(sat, rounds: 4)
        t.join(5)
        server.close
        expect(got).to include("voice-stopped", "transcript", "synthesize", "audio-start", "audio-chunk", "audio-stop")
        expect([ luz.reload.value, luz_quarto.reload.value ]).to eq([ false, true ])
        expect(AssistRun.last).to have_attributes(source: "satellite", satellite_id: sat.id, heard: "acenda a luz")
        expect(sat.reload.last_seen_at).to be_present
        expect(Assist.call(site: site, user: nil, text: "deixe a luz da sala em 10%", satellite: sat)["text"]).to include("não posso comandar Lâmpada")
      end
    end

    it "satélite ESPHome (Voice PE): pedido, áudio pela API, eventos do pipeline com a URL da fala" do
      fake_engine = Class.new(Assist::Engines::Base) do
        describe key: "teste_esp", label: "Teste ESP", kinds: %i[stt tts]
        texts en: { label: "ESP test" }, es: { label: "Prueba ESP" }
        def self.transcribe(*, **) = "ligar a luz da sala"
        def self.speak(*, **) = { data: "mp3", media_type: "audio/mpeg" }
      end
      stub_const("Assist::Engines::TesteEsp", fake_engine)
      stub_const("Assist::Engines::PLUGINS", Assist::Engines::PLUGINS + %w[TesteEsp])
      pl = AssistPipeline.create!(site: site, name: "Teste esp", stt: { "engine" => "teste_esp" }, tts: { "engine" => "teste_esp" })
      dev = create(:device, site: site, name: "Voice PE", driver: "esphome", address: { "host" => "10.0.0.9" })
      sat = AssistSatellite.create!(site: site, name: "Teste PE", kind: "esphome", device: dev, pipeline: pl, area: sala)
      sent = []
      inbox = [ [ 90, { 1 => [ 1 ], 2 => [ "conv-1" ] } ], [ 106, { 1 => [ "\x00\x00".b * 800 ], 2 => [ 1 ] } ] ]
      client = Object.new
      client.define_singleton_method(:send_message) { |type, fields = []| sent << [ type, fields ] }
      client.define_singleton_method(:read) { |_t| inbox.shift }
      client.define_singleton_method(:close) { nil }
      Assist::Satellites::EsphomeSatellite.serve(sat, rounds: 2, client: client)
      expect(sent.map(&:first).first(2)).to eq([ 89, 91 ])
      events = sent.select { |t, _| t == 92 }
      ev = Assist::Satellites::EsphomeSatellite::EVENTS
      expect(events.map { |_, f| f.first.last }).to eq(ev.values_at(:run_start, :stt_start, :stt_vad_end, :stt_end, :intent_start, :intent_end, :tts_start, :tts_end, :run_end))
      url = Proto.decode(events[-2].last.last.last)
      expect([ Proto.string(url[1].first), Proto.string(url[2].first) ]).to match([ "url", %r{\Ahttp://.+/rails/active_storage/} ])
      expect(luz.reload.value).to be true
    end

    it "tipo de satélite novo entra pelo registro e o ouvinte o serve" do
      served = []
      fake = Class.new(Assist::Satellites::Base) do
        describe key: "teste_sat", label: "Teste satélite", needs: []
        texts en: { label: "Test satellite" }, es: { label: "Satélite de prueba" }
        define_singleton_method(:serve) { |sat, rounds: nil| served << [ sat.name, rounds ] }
      end
      stub_const("Assist::Satellites::TesteSat", fake)
      stub_const("Assist::Satellites::PLUGINS", Assist::Satellites::PLUGINS + %w[TesteSat])
      sat = AssistSatellite.create!(site: site, name: "Teste x", kind: "teste_sat")
      expect(Assist::Satellites::Listener.run_once(sat.id, rounds: 1)).to be true
      expect(served).to eq([ [ "Teste x", 1 ] ])
      expect(AssistSatellite.new(site: site, name: "y", kind: "wyoming")).not_to be_valid # sem endereço
      expect(AssistSatellite.new(site: site, name: "z", kind: "teste_sat", role: "owner")).not_to be_valid
    end
  end

  describe "B7 servidor MCP" do
    def rpc(method, params = {}, id: 1, user: owner) = Assist::Mcp.handle({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }, site: site, user: user)

    it "initialize, tools/list (intenções + contexto) e tools/call com papel x risco, registrado na depuração" do
      expect(rpc("initialize", { "protocolVersion" => "2025-03-26" })["result"]).to include("protocolVersion" => "2025-03-26", "serverInfo" => include("name" => "Minha Automação"))
      expect(Assist::Mcp.handle({ "jsonrpc" => "2.0", "method" => "notifications/initialized" }, site: site, user: owner)).to be_nil
      names = rpc("tools/list")["result"]["tools"].pluck("name")
      expect(names).to include("turn_on", "light_brightness", "timer_start", "todo_add", "get_live_context")
      expect(names).not_to include("nevermind", "conversation")
      expect(rpc("tools/list")["result"]["tools"].find { |t| t["name"] == "light_brightness" }["inputSchema"]["properties"]["brightness"]).to include("type" => "number")

      luz_quarto.update!(expose: { "assist" => false })
      ctx = rpc("tools/call", { "name" => "get_live_context" })["result"]["content"].first["text"]
      expect(ctx).to include("Luz Lâmpada (Sala) [onoff]")
      expect(ctx).not_to include("Abajur")
      r = rpc("tools/call", { "name" => "turn_on", "arguments" => { "name" => "luz da sala" } })["result"]
      expect(r).to include("isError" => false, "content" => [ { "type" => "text", "text" => "Liguei Luz." } ])
      expect(luz.reload.value).to be true
      expect(AssistRun.find_by(intent: "turn_on")).to have_attributes(source: "mcp", intent: "turn_on", reply: "Liguei Luz.", user_id: owner.id)

      guest = create(:user, tenant: tenant, role: "member")
      create(:site_membership, site: site, user: guest, role: "guest")
      brilho.update!(risk: "sensitive")
      expect(rpc("tools/call", { "name" => "light_brightness", "arguments" => { "name" => "luz da sala", "brightness" => 10 } }, user: guest)["result"]["content"].first["text"]).to include("não posso comandar Lâmpada")
      expect(rpc("tools/call", { "name" => "rm" })["result"]["isError"]).to be true
      expect(rpc("nada")["error"]).to include("code" => -32_601)
      expect(Assist::Mcp.handle({ "id" => 1 }, site: site, user: owner)["error"]["code"]).to eq(-32_600)
      expect(Assist::Mcp.handle([ { "jsonrpc" => "2.0", "id" => 7, "method" => "ping" } ], site: site, user: owner)).to eq([ { "jsonrpc" => "2.0", "id" => 7, "result" => {} } ])
    end

    it "ferramenta nova entra pelo registro de intenções e já aparece no MCP" do
      fake = Class.new(Assist::Intent) do
        describe key: "teste_eco", slots: %w[texto], description: "Eco de teste", sentences: {}
        texts en: { description: "Test echo" }, es: { description: "Eco de prueba" }
        def self.handle(_ctx, slots) = reply("eco #{slots['texto']}")
      end
      stub_const("Assist::Intents::TesteEco", fake)
      stub_const("Assist::INTENTS", Assist::INTENTS + %w[TesteEco])
      expect(rpc("tools/list")["result"]["tools"].pluck("name")).to include("teste_eco")
      expect(rpc("tools/call", { "name" => "teste_eco", "arguments" => { "texto" => "oi" } })["result"]["content"].first["text"]).to eq("eco oi")
    end
  end

  describe "B3 Assist multilíngue" do
    it "en e es: liga, brilho, timer, lista e respostas no idioma da frase" do
      expect(say("turn on the living room light", language: "en")).to include("intent" => "turn_on", "text" => "Turned on Luz.", "language" => "en")
      expect(say("set the living room light to 30%", language: "en")["text"]).to eq("Set Lâmpada brightness to 30%.")
      expect(say("set a timer for 2 minutes", language: "en")["text"]).to eq("2 minutes timer started.")
      expect(say("what time is it", language: "en")["intent"]).to eq("get_time")
      expect(say("apaga la luz de la sala", language: "es")["text"]).to eq("Apagué Luz.")
      expect(say("pon un temporizador de 3 minutos", language: "es")["text"]).to eq("Temporizador de 3 minutos iniciado.")
      HelperTypes.save(HelperTypes.build(site, HelperTypes::TodoList), "name" => "Shopping")
      expect(say("add milk to my shopping list", language: "en")["text"]).to eq("Added milk to Shopping.")
    end

    it "idioma: o pedido, o do local ou o da tela; frase em pt não vale em en" do
      expect(Assist.language("pt")).to eq("pt-BR")
      expect(Assist.language("en-US")).to eq("en")
      expect(Assist.language("fr")).to eq("pt-BR")
      site.update!(language: "es")
      expect(say("enciende la luz de la sala")["text"]).to eq("Encendí Luz.")
      allow(Ai::Ask).to receive(:call).and_return("?")
      expect(say("ligar a luz da sala", language: "en")["intent"]).to eq("ask")
    end
  end
end
