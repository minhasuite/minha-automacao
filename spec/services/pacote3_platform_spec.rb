require "rails_helper"

# Pacote 3: voz local (Assist), loja de pacotes (Packages, DeviceMaps) e
# ferramentas de desenvolvedor (DevTools). Tudo por registro; sem rede.
RSpec.describe "Pacote 3: plataforma" do
  let(:tenant) { create(:tenant) }
  let(:owner) { create(:user, tenant: tenant, role: "owner") }
  let(:site) { create(:site) }
  let(:room) { create(:area, site: site, name: "Sala") }
  let(:device) { create(:device, site: site, area: room, name: "Interruptor") }
  let!(:lamp) { create(:point, site: site, device: device, name: "Luz", value: false, alexa_name: "Abajur") }
  let!(:temp) { create(:point, site: site, device: create(:device, site: site, area: room, name: "Termômetro"), name: "Temperatura", capability: "measure", value: 25.4, unit: "°C") }
  let!(:gate) { create(:point, site: site, device: create(:device, site: site, name: "Garagem"), name: "Portão", capability: "onoff", risk: "critical", value: false) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  describe "assistente de voz" do
    def say(text, user: owner) = Assist.call(site: site, user: user, text: text)

    it "liga e desliga pelo nome, pelo apelido e por 'ponto da área', sem IA" do
      r = say("Ligar a luz da sala, por favor")
      expect(r).to include("intent" => "turn_on", "text" => "Liguei Luz.", "heard" => "Ligar a luz da sala, por favor")
      expect(lamp.reload.value).to be true
      expect(Command.last).to have_attributes(source: "voice", user_id: owner.id)
      expect(say("desligue o abajur")["text"]).to eq("Desliguei Luz.")
      expect(lamp.reload.value).to be false
      expect(say("acender a sala")["points"]).to eq([ lamp.id ]) # a área inteira (o que liga)
    end

    it "lê o estado e respeita risco e papel: crítico nunca por voz; convidado não comanda sensível" do
      expect(say("qual a temperatura da sala")["text"]).to eq("Termômetro Temperatura: 25,4 °C.")
      expect(say("abrir o portão")["intent"]).to eq("unknown").or eq("ask")
      expect(say("ligar o portão")["text"]).to eq("Por voz não posso comandar Portão.")
      expect(gate.reload.value).to be false

      guest = create(:user, tenant: tenant, role: "member")
      create(:site_membership, site: site, user: guest, role: "guest")
      lamp.update!(risk: "sensitive")
      expect(say("ligar a luz", user: guest)["text"]).to include("não posso comandar Luz")
    end

    it "na sombra o aparelho não recebe nada" do
      site.update!(shadow: true)
      expect(say("ligar a luz")["text"]).to include("Não consegui")
      expect(lamp.reload.value).to be false
      expect(ShadowAction.count).to eq(1)
    end

    it "ativa cena pelo nome e cai no Perguntar à casa quando não reconhece" do
      scene = site.scenes.create!(name: "Cinema", items: [ { "point_id" => lamp.id, "command" => "on" } ])
      expect(say("ativar a cena cinema")["text"]).to eq("Cena Cinema acionada.")
      expect(lamp.reload.value).to be true
      expect(scene).to be_persisted

      allow(Ai::Ask).to receive(:call).and_return("Está tudo calmo.")
      expect(say("tem alguém na varanda?")).to include("intent" => "ask", "text" => "Está tudo calmo.")
      allow(Ai::Ask).to receive(:call).and_raise(Ai::Client::Error, "sem provedor")
      expect(say("tem alguém na varanda?")["intent"]).to eq("unknown")
      expect { say("  ") }.to raise_error(ArgumentError)
    end

    it "uma intenção nova entra pelo registro sem mudar o assistente" do
      fake = Class.new do
        def self.pattern = /\Abom dia\z/
        def self.handle(_ctx, _m) = Assist::Reply.new(text: "Bom dia! A casa está pronta.", intent: "greeting")
      end
      stub_const("Assist::Intents::Greeting", fake)
      stub_const("Assist::INTENTS", %w[Greeting] + Assist::INTENTS)
      expect(say("Bom dia!")).to include("intent" => "greeting", "text" => "Bom dia! A casa está pronta.")
    end

    it "fala (TTS) e áudio (STT) pelo provedor de voz da instalação" do
      allow(Ai::Audio).to receive(:speak).and_return(Ai::Audio::Result.new(data: { data: "mp3", media_type: "audio/mpeg" }, provider: "x", model: "y"))
      out = Assist.call(site: site, user: owner, text: "qual a temperatura da sala", speak: true)
      expect(out["audio_url"]).to include("/rails/active_storage/")
      allow(Ai::Audio).to receive(:transcribe).and_return(Ai::Audio::Result.new(data: " ligar a luz ", provider: "x", model: "y"))
      expect(Assist.transcribe(site: site, audio: "bytes", media_type: "audio/webm")).to eq("ligar a luz")
      allow(Ai::Audio).to receive(:speak).and_raise(Ai::Client::Error, "sem tts")
      expect(Assist.call(site: site, user: owner, text: "qual a temperatura da sala", speak: true)["audio_url"]).to be_nil
    end
  end

  describe "loja de pacotes" do
    let(:manifest) do
      { "format" => 1, "key" => "basico", "name" => "Básico", "version" => "1.0.0", "description" => "Teste",
        "items" => [
          { "type" => "blueprint", "key" => "luz-movimento", "name" => "Luz por movimento", "domain" => "automation", "mode" => "restart",
            "inputs" => [ { "key" => "luz", "label" => "Luz", "type" => "point" } ],
            "definition" => { "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "command", "point" => { "!input" => "luz" }, "command" => "on" } ] } },
          { "type" => "helper", "key" => "modo", "name" => "Modo da casa", "helper" => "select", "form" => { "options_text" => "Casa, Fora" } },
          { "type" => "dashboard", "key" => "painel", "name" => "Painel do pacote",
            "definition" => { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "Início", "sections" => [ { "id" => "s", "widgets" => [ { "id" => "w", "type" => "heading", "title" => "Oi" } ] } ] } ] } },
          { "type" => "device_map", "key" => "tomada-x", "map" => "tuya", "data" => { "codes" => { "zz_power_x" => { "name" => "Potência X", "capability" => "measure", "unit" => "W" } } } }
        ] }
    end

    def serve(url, body, status: 200) = stub_request(:get, url).to_return(status: status, body: body.is_a?(String) ? body : body.to_json)

    it "busca no GitHub (raiz do repo), valida, mostra o plano e instala nos registros existentes" do
      serve("https://raw.githubusercontent.com/dono/repo/HEAD/minha-automacao.json", manifest)
      m, url = Packages.fetch("https://github.com/dono/repo")
      expect(url).to end_with("/HEAD/minha-automacao.json")
      expect(Packages.errors(m, site)).to eq([])
      expect(Packages.preview(site, m).map { |i| [ i["type"], i["action"] ] }).to eq([ %w[blueprint add], %w[helper add], %w[dashboard add], %w[device_map add] ])

      expect(Tuya::Cloud.known("zz_power_x")).to be_nil
      package = Packages.install!(site, m, url)
      expect(package).to have_attributes(key: "basico", version: "1.0.0")
      expect(site.blueprints.find_by!(name: "Luz por movimento").source).to eq("package:basico")
      expect(site.points.helpers.find_by!(name: "Modo da casa").options).to eq(%w[Casa Fora])
      expect(site.dashboards.find_by!(name: "Painel do pacote")).to be_present
      expect(Tuya::Cloud.known("zz_power_x")).to include("name" => "Potência X")
      expect(DeviceMaps.get("tuya")["codes"]).to include("zz_power_x")
    end

    it "atualiza (troca, tira o que saiu) e remove tudo o que pôs, sem tocar no resto" do
      mine = site.blueprints.create!(name: "Meu", definition: { "triggers" => [ { "type" => "manual" } ], "actions" => [] })
      package = Packages.install!(site, manifest, "https://x.test/m.json")
      v2 = manifest.merge("version" => "1.1.0", "items" => [ manifest["items"][0].merge("name" => "Luz por presença") ])
      expect(Packages.newer?("1.1.0", "1.0.0")).to be true
      expect(Packages.preview(site, v2, package).map { |i| i["action"] }).to eq(%w[update remove remove remove])
      Packages.install!(site, v2, "https://x.test/m.json")
      expect(site.blueprints.pluck(:name)).to contain_exactly("Meu", "Luz por presença")
      expect(site.points.helpers.where(name: "Modo da casa")).to be_empty
      expect(Tuya::Cloud.known("zz_power_x")).to be_nil

      Packages.uninstall!(package.reload)
      expect(site.blueprints.pluck(:name)).to eq([ "Meu" ])
      expect(site.packages.reload).to be_empty
      expect(mine.reload).to be_persisted
    end

    it "recusa o que não é dado: tipo desconhecido, seção de mapa com regex, formato e campos ruins" do
      bad = manifest.merge("format" => 2, "key" => "X", "version" => "um", "items" => [
                             { "type" => "ruby", "key" => "xx" }, { "type" => "device_map", "key" => "mapa", "map" => "tuya", "data" => { "patterns" => [ { "match" => ".*" } ] } },
                             { "type" => "helper", "key" => "hh", "name" => "H", "helper" => "nao_existe" },
                             { "type" => "blueprint", "key" => "bb", "name" => "", "definition" => {} }, { "type" => "blueprint", "key" => "bb", "name" => "B2" }
                           ])
      errors = Packages.errors(bad, site).join(" | ")
      expect(errors).to include("format precisa ser 1", "key inválida", "version inválida", "tipo \"ruby\" não existe", "seções não permitidas: patterns",
                                "helper \"nao_existe\" não existe", "key \"bb\" repetida")
      expect { Packages.install!(site, bad, "https://x.test/m.json") }.to raise_error(Packages::Error)
      expect(site.packages.reload).to be_empty
      expect(DeviceMaps.plain?({ "a" => [ 1, "b", { "c" => true } ] })).to be true
      expect(DeviceMaps.plain?({ "a" => Object.new })).to be false
    end

    it "fontes: GitLab, URL de manifesto YAML, 404 em todas e endereço que não é de pacote" do
      serve("https://gitlab.com/grupo/repo/-/raw/HEAD/minha-automacao.json", "", status: 404)
      serve("https://gitlab.com/grupo/repo/-/raw/HEAD/minha-automacao.yml", manifest.to_yaml)
      expect(Packages.fetch("https://gitlab.com/grupo/repo.git").first["key"]).to eq("basico")
      serve("https://exemplo.com/pacote.yaml", "a: [1")
      expect { Packages.fetch("https://exemplo.com/pacote.yaml") }.to raise_error(Packages::Error, /inválido/)
      %w[json yml yaml].each { |ext| serve("https://raw.githubusercontent.com/a/b/v2/minha-automacao.#{ext}", "", status: 404) }
      expect { Packages.fetch("https://github.com/a/b/tree/v2") }.to raise_error(Packages::Error, /não encontrado/)
      expect { Packages.fetch("ftp://x/y") }.to raise_error(Packages::Error, /não reconhecido/)
      expect { Packages.fetch("https://192.168.0.1/m.json") }.to raise_error(Packages::Error, /baixar/)
    end

    it "uma fonte e um tipo de item novos entram pelo registro" do
      source = Class.new do
        def self.match?(url) = url.start_with?("pacote://")
        def self.candidates(url) = [ "https://espelho.test/#{url.delete_prefix('pacote://')}.json" ]
      end
      item = Class.new(Packages::Items::Base) do
        describe key: "nota", label: "Nota"
        def self.errors(_site, item) = item["text"].present? ? [] : [ "text obrigatório." ]
        def self.install!(site, item, _package, _old) = site.datasets.create!(name: item["text"]).id
        def self.uninstall!(site, ref) = site.datasets.find_by(id: ref["id"])&.destroy!
      end
      stub_const("Packages::Sources::Mirror", source)
      stub_const("Packages::SOURCES", %w[Mirror] + Packages::SOURCES)
      stub_const("Packages::Items::NoteItem", item)
      stub_const("Packages::ITEMS", Packages::ITEMS + %w[NoteItem])
      serve("https://espelho.test/abc.json", manifest.merge("items" => [ { "type" => "nota", "key" => "n1", "text" => "Diário" } ]))
      m, url = Packages.fetch("pacote://abc")
      package = Packages.install!(site, m, url)
      expect(site.datasets.pluck(:name)).to eq([ "Diário" ])
      Packages.uninstall!(package)
      expect(site.datasets.reload).to be_empty
    end
  end

  describe "ferramentas de desenvolvedor" do
    it "estados com filtro, definir valor só de helper e modelo Liquid/expressão" do
      expect(DevTools.states(site, q: "temp").map(&:id)).to eq([ temp.id ])
      expect(DevTools.state_json(temp)).to include("value" => 25.4, "text" => "25,4 °C")
      expect { DevTools.set_helper!(lamp, "true") }.to raise_error(Points::Command::Error, /Só helper/)
      counter = HelperTypes.build(site, HelperTypes::Counter)
      HelperTypes.save(counter, "name" => "Visitas")
      expect(DevTools.set_helper!(counter, "7").value).to eq(7)

      expect(DevTools.render(site, "{{ 1 | plus: 2 }}")).to eq([ "3", nil ])
      expect(DevTools.render(site, "2 * 3", mode: "expr")).to eq([ 6, nil ])
      expect(DevTools.render(site, "{% if %}").last).to be_present
    end

    it "executar ação respeita a sombra; eventos disparam automações e recusam nome do sistema" do
      site.update!(shadow: true)
      expect { DevTools.command!(lamp, "on", nil, user: owner) }.to raise_error(Shadow::Blocked)
      expect(lamp.reload.value).to be false
      site.update!(shadow: false)
      expect(DevTools.command!(lamp, "on", "", user: owner).status).to eq("confirmed")

      a = Automation.create!(site: site, name: "Ouve", kind: "automation", mode: "queued")
      a.publish!({ "triggers" => [ { "type" => "event", "event" => "teste.ping" } ], "actions" => [ { "type" => "trace_note", "message" => "ok" } ] })
      a.update!(enabled: true)
      expect(DevTools.fire!(site, "teste.ping", '{"n": 1}')).to eq("teste.ping")
      expect(a.runs.count).to eq(1)
      expect { DevTools.fire!(site, "system_started", "{}") }.to raise_error(ArgumentError, /sistema/)
      expect { DevTools.fire!(site, "x", "[1") }.to raise_error(ArgumentError, /JSON/)
      expect { DevTools.fire!(site, "Nome Ruim", "{}") }.to raise_error(ArgumentError, /inválido/)
    end
  end
end
