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
      expect(say("deixe a luz da sala em 70%")).to include("intent" => "light_brightness", "text" => "Brilho de Brilho em 70%.")
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

      expect(say("coloque o ar em 22 graus")).to include("intent" => "climate_set_temperature", "text" => "Alvo em 22 °C.")
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
      expect(Command.where(point: robo).pluck(:command)).to eq(%w[start home])
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
      expect(say("deixe a luz da sala em 10%", user: guest)["text"]).to include("não posso comandar Brilho")
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

  describe "B3 Assist multilíngue" do
    it "en e es: liga, brilho, timer, lista e respostas no idioma da frase" do
      expect(say("turn on the living room light", language: "en")).to include("intent" => "turn_on", "text" => "Turned on Luz.", "language" => "en")
      expect(say("set the living room light to 30%", language: "en")["text"]).to eq("Set Brilho brightness to 30%.")
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
