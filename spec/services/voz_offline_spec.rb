require "rails_helper"

# voz-offline: pipeline local primeiro (Whisper/Piper pelo Wyoming), queda
# para a nuvem configurável, IA só se permitida e com internet, intenções
# mais completas e a casa funcionando com a nuvem bloqueada (WebMock).
# Nada de rede: Wyoming por stub, nuvem bloqueada e conferida sem pedido.
RSpec.describe "voz-offline: voz de ponta a ponta sem internet" do
  let(:tenant) { create(:tenant) }
  let(:owner) { create(:user, tenant: tenant, role: "owner") }
  let(:site) { create(:site) }
  let(:sala) { create(:area, site: site, name: "Sala") }
  let(:cozinha) { create(:area, site: site, name: "Cozinha") }
  let(:lampada) { create(:device, site: site, area: sala, name: "Lâmpada") }
  let!(:luz) { create(:point, site: site, device: lampada, name: "Luz", value: false) }
  let!(:abajur) { create(:point, site: site, device: create(:device, site: site, area: sala, name: "Abajur"), name: "Abajur", value: false) }
  let!(:porta) do
    create(:point, site: site, device: create(:device, site: site, area: cozinha, name: "Sensor porta"), name: "Porta", capability: "contact", device_class: "door",
                   value: true, writable: false)
  end
  let(:cloud) { %r{api\.anthropic\.com|api\.openai\.com|generativelanguage} }
  let(:wav) { Wyoming.wav("\x00\x00".b * 1600, 16_000, 2, 1) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def say(text, **opts) = Assist.call(site: site, user: owner, text: text, **opts)

  # Sem internet "de verdade": o probe roda e a WebMock derruba a conexão.
  def go_offline!
    allow(Internet).to receive(:probe).and_call_original
    stub_request(:head, Internet::URL).to_timeout
    stub_request(:any, cloud).to_raise(SocketError.new("sem rede"))
    Internet.reset!
  end

  def local_voice!
    AiAccount.create!(provider: "wyoming", base_url: "tcp://192.0.2.10")
    allow(Wyoming).to receive(:transcribe).and_return("ligar a luz da sala")
    allow(Wyoming).to receive(:synthesize).and_return({ data: wav, media_type: "audio/wav" })
  end

  describe "Internet" do
    it "HEAD no endereço de conectividade; rede caída ou tempo esgotado = offline; MA_OFFLINE força" do
      allow(Internet).to receive(:probe).and_call_original
      stub_request(:head, Internet::URL).to_return(status: 204)
      expect(Internet.online?).to be true
      Internet.reset!
      stub_request(:head, Internet::URL).to_raise(SocketError)
      expect(Internet.online?).to be false
      expect(Internet.offline?).to be true # do cache
      Internet.reset!
      stub_request(:head, Internet::URL).to_return(status: 204)
      old = ENV.fetch("MA_OFFLINE", nil)
      ENV["MA_OFFLINE"] = "1"
      expect(Internet.online?).to be false
    ensure
      ENV["MA_OFFLINE"] = old
    end
  end

  describe "pipeline sem internet (nuvem bloqueada)" do
    before do
      AiAccount.create!(provider: "anthropic", api_key: "sk-teste")
      AiAccount.create!(provider: "openai", api_key: "sk-teste")
      go_offline!
    end

    it "fala → Whisper local → intenção → Piper local, sem um pedido para a nuvem" do
      local_voice!
      out = Assist::Pipeline.run(site: site, user: owner, audio: wav, media_type: "audio/wav", speak: true)
      expect(out).to include("heard" => "ligar a luz da sala", "intent" => "turn_on", "offline" => true, "audio_url" => be_present)
      expect(out["stages"].map { |s| s.values_at("stage", "engine", "provider", "where") })
        .to eq([ [ "stt", "auto", "wyoming", "local" ], [ "intent", nil, nil, nil ], [ "tts", "auto", "wyoming", "local" ] ])
      expect(out["stages"]).to all(include("ms" => be >= 0))
      expect(luz.reload.value).to be true
      expect(a_request(:any, cloud)).not_to have_been_made
    end

    it "frase fora das intenções: responde o modo offline em vez de chamar a IA da nuvem" do
      out = Assist::Pipeline.run(site: site, user: owner, text: "conte uma piada")
      expect(out).to include("intent" => "offline", "offline" => true)
      expect(out["text"]).to include("sem internet", "conte uma piada")
      pl = AssistPipeline.create!(site: site, name: "IA", agent: "local_llm", preferred: true)
      expect(Assist::Pipeline.run(site: site, user: owner, text: "conte uma piada", pipeline: pl)["intent"]).to eq("offline")
      expect(a_request(:any, cloud)).not_to have_been_made
      expect(AiCall.count).to eq(0)
    end

    it "sem voz local e sem internet: erro claro (e a execução registrada com a etapa)" do
      expect { Assist::Pipeline.run(site: site, user: owner, audio: wav, media_type: "audio/wav") }
        .to raise_error(Ai::Client::Error, /Whisper/)
      run = AssistRun.last
      expect(run.stages.first).to include("stage" => "stt", "engine" => "auto", "error" => /Whisper/)
    end

    it "Ollama da rede da casa continua respondendo o que as intenções não entendem" do
      AiAccount.create!(provider: "ollama", base_url: "http://192.0.2.60:11434")
      allow(Ai::Ask).to receive(:call).and_return("São 3 luzes.")
      expect(say("me explique a casa")).to include("intent" => "ask", "text" => "São 3 luzes.")
    end
  end

  describe "com internet: local primeiro, nuvem como queda (se o pipeline deixar)" do
    before { AiAccount.create!(provider: "openai", api_key: "sk-teste") }

    it "Whisper caiu → usa a nuvem; `cloud: false` → não usa" do
      AiAccount.create!(provider: "wyoming", base_url: "tcp://192.0.2.10")
      allow(Wyoming).to receive(:transcribe).and_raise(Wyoming::Error, "Wyoming 192.0.2.10:10300: recusou")
      stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(status: 200, body: { text: "apagar a luz da sala" }.to_json,
                                                                                    headers: { "Content-Type" => "application/json" })
      out = Assist::Pipeline.run(site: site, user: owner, audio: wav, media_type: "audio/wav")
      expect(out).to include("heard" => "apagar a luz da sala", "offline" => false)
      expect(out["stages"].first).to include("provider" => "openai", "where" => "cloud")

      pl = AssistPipeline.create!(site: site, name: "Só casa", cloud: false, preferred: true)
      expect { Assist::Pipeline.run(site: site, user: owner, audio: wav, media_type: "audio/wav", pipeline: pl) }
        .to raise_error(Ai::Client::Error, /wyoming: Wyoming/)
      expect(a_request(:post, %r{api\.openai\.com})).to have_been_made.once
    end

    it "agente só intenções: não chama IA nenhuma, mesmo online" do
      pl = AssistPipeline.create!(site: site, name: "Sem IA", agent: "intents", preferred: true)
      expect(Ai::Ask).not_to receive(:call)
      out = Assist::Pipeline.run(site: site, user: owner, text: "qual o sentido da vida", pipeline: pl)
      expect(out).to include("intent" => "unknown")
      expect(out["text"]).to start_with("Não entendi")
    end

    it "teste sem executar: reconhece a intenção e não comanda" do
      out = Assist::Pipeline.run(site: site, user: owner, text: "ligar a luz da sala", execute: false, source: "test")
      expect(out).to include("intent" => "turn_on", "dry_run" => true, "slots" => { "name" => "a luz da sala" })
      expect(out["text"]).to start_with("Entendi:")
      expect(luz.reload.value).to be false
      expect(Command.count).to eq(0)
      expect(AssistRun.last.source).to eq("test")
    end
  end

  describe "intenções locais mais completas" do
    it "cortesia e palavra de ativação no começo" do
      expect(say("ok casa pode ligar a luz da sala por favor")["intent"]).to eq("turn_on")
      expect(say("por favor, apague a luz da sala")["intent"]).to eq("turn_off")
      expect(say("me diga se a porta da cozinha está aberta")["text"]).to start_with("Sim.")
    end

    it "estado com o verbo antes ('está aberta a porta da cozinha?') e temperatura" do
      expect(say("está aberta a porta da cozinha?")["text"]).to start_with("Sim.")
      expect(say("a porta da cozinha está fechada?")["text"]).to start_with("Não.")
      create(:point, site: site, device: lampada, name: "Temperatura", capability: "measure", device_class: "temperature", unit: "°C", value: 24.5)
      expect(say("qual a temperatura da sala")["text"]).to include("24")
    end

    it "tipo falado: 'as luzes da sala' acha a luz e o abajur sem ponto com esse nome; apelido conta" do
      out = say("apague as luzes da sala")
      expect(out["points"]).to contain_exactly(luz.id, abajur.id)
      abajur.update!(aliases: [ "luminária" ])
      expect(say("ligar a luminária")["points"]).to eq([ abajur.id ])
      expect(say("quantas portas estão abertas")["text"]).to start_with("1:")
    end

    it "ajuste do aparelho (luz de fundo, luz indicadora, trava infantil) não é luz nem entra no cômodo inteiro" do
      esc = create(:area, site: site, name: "Escritório")
      dev = ->(name) { create(:device, site: site, area: esc, name: name) }
      monitor = create(:point, site: site, device: dev.call("ESC Lampada Monitor 1"), name: "Lâmpada Monitor 1", value: true)
      interruptor = dev.call("ESC Interruptor 4 Botoes")
      teto = create(:point, site: site, device: interruptor, name: "Interruptor 4", value: true)
      fundo = create(:point, site: site, device: interruptor, name: "Luz de fundo", value: true)
      ulmos = dev.call("Iluminação Ulmos")
      ulmos_sw = create(:point, site: site, device: ulmos, name: "Liga/desliga", value: true)
      trava = create(:point, site: site, device: ulmos, name: "Trava infantil", value: true)
      led = create(:point, site: site, device: dev.call("Security Camera"), name: "Luz indicadora", value: true)
      expect(say("desligar as luzes do escritório")["points"]).to contain_exactly(monitor.id, ulmos_sw.id)
      expect(say("desligar o escritório")["points"]).to contain_exactly(monitor.id, teto.id, ulmos_sw.id)
      expect(say("desligar a luz indicadora")["points"]).to eq([ led.id ])
      teto.update!(aliases: [ "luz do teto" ])
      expect(say("desligar a luz do teto")["points"]).to eq([ teto.id ])
      expect(say("desligar as luzes do escritório")["points"]).to contain_exactly(monitor.id, ulmos_sw.id, teto.id) # o apelido com "luz" conta
      [ fundo, trava ].each { |p| expect(p.reload.value).to be true }
      site.update!(settings: site.settings.to_h.merge("assist_settings" => [ "Liga/desliga" ]))
      expect(say("desligar as luzes do escritório")["points"]).to contain_exactly(monitor.id, teto.id)
    end

    describe "qual delas? (pedido no singular com várias opções)" do
      let(:esc) { create(:area, site: site, name: "Escritório") }
      let!(:m1) { create(:point, site: site, device: create(:device, site: site, area: esc, name: "ESC Lampada Monitor 1"), name: "Lâmpada Monitor 1", value: true) }
      let!(:m2) { create(:point, site: site, device: create(:device, site: site, area: esc, name: "ESC Lampada Monitor 2"), name: "Lâmpada Monitor 2", value: true) }
      let!(:teto) do
        create(:point, site: site, device: create(:device, site: site, area: esc, name: "ESC Interruptor"), name: "Interruptor 4", aliases: [ "luz do teto" ],
                       value: true)
      end

      before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

      it "pergunta, não comanda, e a resposta curta escolhe pelo nome, pela ordem ou todas" do
        out = say("desligue a luz do escritório")
        expect(out).to include("intent" => "clarify", "points" => [])
        expect(out["text"]).to include("Achei 3", "Lâmpada Monitor 1", "Interruptor 4", "Qual delas?")
        expect(Command.count).to eq(0)

        expect(say("a do teto")).to include("intent" => "turn_off", "points" => [ teto.id ])
        expect(say("a do teto")["intent"]).not_to eq("turn_off") # a pergunta já foi respondida

        say("desligue a luz do escritório")
        expect(say("a segunda")["points"]).to eq([ m2.id ])
        say("desligue a luz do escritório")
        expect(say("monitor")).to include("intent" => "clarify") # ainda duas: pergunta de novo só com elas
        expect(say("1")["points"]).to eq([ m1.id ])
        say("desligue a luz do escritório")
        expect(say("todas")["points"]).to contain_exactly(m1.id, m2.id, teto.id)
      end

      it "plural, cômodo inteiro e nome exato fazem direto; cancela e resposta sem opção" do
        expect(say("desligue as luzes do escritório")["points"]).to contain_exactly(m1.id, m2.id, teto.id)
        expect(say("desligue o escritório")["points"]).to contain_exactly(m1.id, m2.id, teto.id)
        expect(say("desligue a luz do teto")["points"]).to eq([ teto.id ])

        say("desligue a luz do escritório")
        expect(say("cancela")["text"]).to eq("Tudo bem, não mexi em nada.")
        say("desligue a luz do escritório")
        expect(say("a da varanda")["text"]).to start_with("Não achei \"a da varanda\" entre as opções")
        expect(say("ligar a luz da sala")).to include("intent" => "turn_on", "points" => [ luz.id ]) # pedido novo descarta a pergunta
        expect(say("monitor 1")["intent"]).not_to eq("turn_off")
      end

      it "a pergunta é da conversa: outra pessoa não responde por ela" do
        say("desligue a luz do escritório")
        outro = create(:user, tenant: tenant, role: "owner")
        expect(Assist.call(site: site, user: outro, text: "todas")["points"]).to eq([])
        expect(say("todas")["points"]).to contain_exactly(m1.id, m2.id, teto.id)
      end
    end

    it "o local pode somar tipos falados (sites.settings)" do
      site.update!(settings: site.settings.to_h.merge("assist_kinds" => { "lamp_post" => { "words" => %w[poste], "names" => %w[abajur] } }))
      expect(say("ligar o poste")["points"]).to eq([ abajur.id ])
    end

    it "mede o tempo de resposta: a intenção com 60 pontos sai em bem menos de 1 s" do
      60.times { |i| create(:point, site: site, device: lampada, name: "Tomada #{i}", value: false) }
      out = Assist::Pipeline.run(site: site, user: owner, text: "ligar a luz da sala")
      expect(out["stages"].first["ms"]).to be < 1000
      expect(Assist::Latency.for(site)).to include("intent" => include("n" => 1, "p50" => be < 1000), "total" => include("n" => 1))
    end
  end

  describe "Status" do
    it "de onde vem cada etapa (local, nuvem, nenhum) e a verificação dos servidores Wyoming" do
      expect(Assist::Status.for(site)).to include("offline" => false, "stt" => { "mode" => "none" }, "ai" => { "mode" => "none" })
      AiAccount.create!(provider: "openai", api_key: "sk")
      AiAccount.create!(provider: "wyoming", base_url: "tcp://192.0.2.10")
      expect(Assist::Status.for(site)).to include("stt" => { "mode" => "local", "provider" => "wyoming" }, "ai" => { "mode" => "cloud", "provider" => "openai" })
      allow(Wyoming).to receive(:describe).and_return({ "asr" => [ { "name" => "faster-whisper" } ] })
      servers = Assist::Status.for(site, nil, check: true)["servers"]
      expect(servers.map { |s| s.values_at("kind", "port", "ok", "detail") }).to eq([ [ "stt", 10_300, true, "faster-whisper" ], [ "tts", 10_200, true, "faster-whisper" ] ])
      allow(Wyoming).to receive(:describe).and_raise(Wyoming::Error, "recusou")
      expect(Assist::Status.for(site, nil, check: true)["servers"].first).to include("ok" => false, "detail" => "recusou")

      pl = AssistPipeline.create!(site: site, name: "Fechado", cloud: false, agent: "intents",
                                  tts: { "engine" => "wyoming", "host" => "192.0.2.11" }, stt: { "engine" => "installation" })
      go_offline!
      st = Assist::Status.for(site, pl)
      expect(st).to include("offline" => true, "cloud" => false, "ai" => { "mode" => "off" }, "tts" => { "mode" => "local", "provider" => "wyoming" })
    end
  end
end
