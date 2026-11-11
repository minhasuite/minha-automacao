require "rails_helper"

# P2.1 (regras de arrumação como dado) e as ideias 3, 6 e 8: o padrão
# serializado reproduz as regras que estavam no código (comparado com a cópia
# congelada em spec/support/legacy), regras editáveis, visão automática,
# montagem por frase com provedor de IA falso e o assistente.
RSpec.describe "Arrumação dos painéis" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:andar) { within(tenant) { create(:area, site: site, name: "Térreo", kind: "floor") } }
  let!(:cozinha) { within(tenant) { create(:area, site: site, name: "Cozinha", parent: andar) } }
  let!(:sala) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let!(:garagem) { within(tenant) { create(:area, site: site, name: "Garagem") } }
  let!(:dev) { within(tenant) { create(:device, site: site, area: cozinha, name: "Cozinha") } }
  let!(:sala_dev) { within(tenant) { create(:device, site: site, area: sala, name: "Tomada TV") } }
  let!(:gar_dev) { within(tenant) { create(:device, site: site, area: garagem, name: "Portão") } }
  let!(:auto_dev) { within(tenant) { create(:device, site: site, name: "Automações", driver: "virtual", external_id: "automations") } }

  let!(:luz) { pt(dev, "Luz", writable: true, value: false) }
  let!(:fita) { pt(dev, "Fita", writable: true, value: false) }
  let!(:dimmer) { pt(dev, "Pendente", capability: "dimmer", writable: true, value: 30) }
  let!(:porta) { pt(dev, "Abertura", capability: "contact", device_class: "door", writable: false, value: false) }
  let!(:movimento) { pt(dev, "Movimento", capability: "motion", writable: false, value: false) }
  let!(:bateria) { pt(dev, "Bateria", capability: "measure", device_class: "battery", unit: "%", writable: false, value: 80) }
  let!(:fechadura) { pt(dev, "Fechadura", capability: "onoff", device_class: "lock", writable: true, value: true) }
  let!(:echo) { pt(dev, "Falar", capability: "speaker", writable: true) }
  let!(:cam) { pt(dev, "Câmera", capability: "stream", device_class: "motion", writable: false) }
  let!(:temp) { pt(dev, "Temperatura", capability: "measure", unit: "°C", writable: false, value: 24) }
  let!(:script) { pt(dev, "Rotina", capability: "script", writable: true) }
  let!(:automacao) { pt(dev, "Push ao abrir", writable: true, value: true, address: { "automation_id" => SecureRandom.uuid }) }
  let!(:auto_ponto) { pt(auto_dev, "Regar", writable: true, value: true) }
  let!(:tv) { pt(sala_dev, "Painel TV", writable: true, value: true) }
  let!(:potencia) { pt(sala_dev, "Potência", capability: "measure", unit: "W", value: 120) }
  let!(:potencia2) { pt(sala_dev, "Consumo", capability: "measure", device_class: "power", unit: "kW", value: 1) }
  let!(:tensao) { pt(sala_dev, "Tensão", capability: "measure", unit: "V", value: 220) }
  let!(:corrente) { pt(sala_dev, "Corrente", capability: "measure", device_class: "current", unit: "A", value: 1) }
  let!(:portao) { pt(gar_dev, "Portão", risk: "critical", value: false) }
  let!(:abajur) { pt(gar_dev, "Abajur", writable: true, value: false) }
  let!(:sensivel) { pt(gar_dev, "Bomba", risk: "sensitive", writable: true, value: false) }
  let(:room) do
    all = [ luz, fita, dimmer, porta, movimento, bateria, fechadura, echo, cam, temp, script, automacao, tv, potencia, tensao ]
    { "id" => "v-cozinha", "title" => "Cozinha", "area" => cozinha.id,
      "badges" => [ { "id" => "b-1", "type" => "stat", "bind" => movimento.id, "aggregate" => "last" } ],
      "sections" => [
        { "id" => "s-1", "widgets" => [ { "id" => "h-1", "type" => "heading", "title" => "Tudo" }, *all.each_with_index.map { |p, i| tile("t-#{i}", p) } ] },
        { "id" => "s-2", "title" => "Outros", "widgets" => [
          { "id" => "st-1", "type" => "stat", "bind" => porta.id },
          { "id" => "g-1", "type" => "gauge", "bind" => bateria.id },
          { "id" => "ch-1", "type" => "chart", "binds" => [ temp.id ] },
          { "id" => "ch-2", "type" => "chart", "bind" => luz.id },
          { "id" => "sb-1", "type" => "scene_bar" },
          { "id" => "bt-1", "type" => "button", "bind" => script.id },
          { "id" => "md-1", "type" => "markdown", "content" => "oi" },
          { "id" => "q-1", "type" => "query_list", "query" => { "capability" => "onoff" } },
          { "id" => "stk", "type" => "stack", "widgets" => [ tile("stk-1", luz), tile("stk-2", movimento) ] },
          { "id" => "stk2", "type" => "stack", "widgets" => [ tile("stk2-1", echo) ] },
          { "id" => "lt-1", "type" => "light", "bind" => temp.id }
        ] }
      ] }
  end

  def pt(device, name, **attrs) = within(tenant) { create(:point, device: device, name: name, **attrs) }

  def tile(id, point, **extra) = { "id" => id, "type" => "tile", "bind" => point.id, "name" => point.name }.merge(extra.stringify_keys)


  describe "padrão serializado = as regras de antes" do
    it "RoomLayout com Arrange::DEFAULT dá o mesmo que a versão com as tabelas no código (e é idempotente)" do
      within(tenant) do
        new_after, new_report = Dashboards::RoomLayout.view(room, site)
        old_after, old_report = LegacyArrange::RoomLayout.view(room, site)
        expect(new_after).to eq(old_after)
        expect(new_report.transform_keys(&:to_s)).to eq(old_report.transform_keys(&:to_s))
        expect(new_after["badges"].map { _1["id"] }).to include("t-3", "t-5") # porta e bateria viram selo
        expect(Dashboards::RoomLayout.view(new_after, site).first).to eq(new_after)
        # Visão menor (2 colunas) e coluna única.
        two = room.merge("sections" => [ { "id" => "x", "widgets" => [ tile("a", luz), tile("b", echo) ] } ])
        expect(Dashboards::RoomLayout.view(two, site).first).to eq(LegacyArrange::RoomLayout.view(two, site).first)
        one = room.merge("sections" => [ { "id" => "x", "widgets" => [ tile("a", porta) ] } ])
        expect(Dashboards::RoomLayout.view(one, site).first).to eq(LegacyArrange::RoomLayout.view(one, site).first)
        # Diferença de propósito: ponto do aparelho "Automações" sem `automation_id` agora também é automação (cenas).
        expect(Dashboards::RoomLayout.new(site).column(tile("a", auto_ponto))).to eq("scenes")
        expect(LegacyArrange::RoomLayout.new(site).column(tile("a", auto_ponto))).to eq(:actions)
        # Pilha que começa com selo: antes quebrava; agora vai para a reserva.
        stack = room.merge("sections" => [ { "id" => "x", "widgets" => [ { "id" => "p", "type" => "stack", "widgets" => [ tile("a", porta) ] } ] } ])
        expect(Dashboards::RoomLayout.view(stack, site).first["sections"].first["id"]).to eq("x")
      end
    end

    it "Generator com Arrange::AUTO_DEFAULT dá o mesmo painel automático que as regex e listas de antes" do
      within(tenant) do
        Tagging.create!(tag: Tag.create!(name: "iluminacao"), taggable: fita)
        site.scenes.create!(name: "Jantar", items: [ { "point_id" => luz.id, "command" => "on" } ])
        I18n.with_locale(:"pt-BR") do
          expect(Dashboards::Generator.call(site)).to eq(LegacyArrange::Generator.call(site))
        end
        home = Dashboards::Generator.call(site)["views"].first
        lights = home["sections"].find { _1["id"] == "s-home-lights" }["widgets"].map { _1["bind"] }
        expect(lights).to include(luz.id, fita.id, abajur.id) # nome, etiqueta e nome
        expect(home["sections"].map { _1["title"] }).to include("Outras áreas")
        I18n.with_locale(:en) { expect(Dashboards::Generator.call(site)["views"].first["sections"].map { _1["title"] }).to include("Other areas") }
      end
    end
  end

  describe "regras editáveis" do
    it "local muda colunas, selos e o automático; o painel pode ter a sua" do
      within(tenant) do
        rules = { "badges" => { "widgets" => [], "match" => [] },
                  "columns" => [ { "id" => "tudo", "title" => "Tudo", "match" => [ { "query" => { "capability" => "onoff" } } ] },
                                 { "id" => "resto", "match" => [] } ], "fallback" => "resto" }
        expect(Dashboards::Arrange.errors(rules)).to eq([])
        site.update!(settings: { "dashboard_defaults" => { "arrange" => rules, "auto_rules" => { "light" => [], "light_names" => false, "power_limit" => 1 } } })
        after, = Dashboards::RoomLayout.view(room, site)
        expect(after["badges"].map { _1["id"] }).to eq([ "b-1" ])
        expect(after["sections"].map { _1["id"] }).to eq(%w[s-1 s-2])
        expect(after["sections"].first["title"]).to eq("Tudo")
        expect(after["sections"].first["widgets"].map { _1["id"] }).to include("t-0", "t-6")

        home = Dashboards::Generator.call(site)["views"].first
        expect(home["sections"].pluck("id")).not_to include("s-home-lights")
        expect(home["sections"].find { _1["id"] == "s-home-energy" }["widgets"].first["binds"].size).to eq(1)

        mine = Dashboards::Arrange::DEFAULT.deep_dup.merge("fallback" => "actions")
        expect(Dashboards::Arrange.rules(site, { "arrange" => mine })).to eq(mine)
        expect(Dashboards::Schema.errors({ "schema_version" => 1, "arrange" => { "columns" => [] }, "views" => [ { "id" => "v", "title" => "V", "sections" => [] } ] }).join)
          .to include("colunas")
      end
    end

    it "valida e lê o formulário (texto chave=valor), sem perder o padrão" do
      bad = { "badges" => { "widgets" => [ "foguete" ], "match" => [ { "query" => { "x" => "1" } }, { "type" => [ "tile" ] } ], "icons" => [] },
              "columns" => [ { "id" => "A B", "full" => [ "nada" ], "match" => "x" }, { "id" => "ok", "title" => 1, "match" => [ {} ] } ], "fallback" => "z" }
      expect(Dashboards::Arrange.errors(bad).join("\n")).to include("tipo de widget", "filtro desconhecido", "cada regra", "ícones", "id com", "título",
                                                                    "até 20", "coluna reserva")
      expect(Dashboards::Arrange.errors([])).to be_present
      expect(Dashboards::Arrange.errors({ "badges" => [] })).to be_present
      expect(Dashboards::Arrange.errors({ "columns" => [ 1 ], "fallback" => "x" }).join).to include("coluna 1")
      expect(Dashboards::Arrange.auto_errors({ "light" => [ { "zz" => "1" } ], "security" => "x", "power_limit" => 9 }).join("\n"))
        .to include("filtro desconhecido", "security", "de 1 a 8")
      expect(Dashboards::Arrange.auto_errors(nil)).to be_present

      d = Dashboards::Arrange::DEFAULT
      form = { "badges" => { "widgets" => d["badges"]["widgets"].join(", "), "queries" => d["badges"]["match"].map { Dashboards::Arrange.query_text(_1["query"]) }.join("\n"),
                             "icons" => d["badges"]["icons"].map { |k, v| "#{k}=#{v}" }.join("\n") },
               "columns" => d["columns"].each_with_index.to_h do |c, i|
                 [ i.to_s, { "id" => c["id"], "full" => Array(c["full"]).join(","), "types" => c["match"].flat_map { Array(_1["type"]) }.join(" "),
                             "queries" => c["match"].filter_map { _1["query"] }.map { Dashboards::Arrange.query_text(_1) }.join("\n") } ]
               end.merge("9" => { "id" => "" }), "fallback" => "media" }
      expect(Dashboards::Arrange.from_form(form)).to eq(d)
      auto = Dashboards::Arrange::AUTO_DEFAULT
      aform = Dashboards::Arrange::AUTO_LISTS.to_h { |k| [ k, auto[k].map { Dashboards::Arrange.query_text(_1) }.join("\n") ] }.merge("light_names" => "1", "power_limit" => "8")
      expect(Dashboards::Arrange.auto_from_form(aform)).to eq(auto)
      expect(Dashboards::Arrange.query_text({ "area" => "Sala de estar" })).to eq('area="Sala de estar"')
      expect { Dashboards::Arrange.queries_from("foo=1") }.to raise_error(ArgumentError)
    end
  end

  describe "visão automática (ideia 6)" do
    it "se refaz com aparelho novo até congelar; os ids levam o da visão" do
      within(tenant) do
        defn = { "schema_version" => 1, "views" => [ { "id" => "home", "title" => "Início", "sections" => [] } ] }
        view = Dashboards::AutoViews.new_area_view(defn, cozinha)
        defn["views"] << view
        defn["views"] << Dashboards::AutoViews.new_area_view(defn, cozinha).merge("auto" => { "area" => cozinha.id, "arrange" => false })
        expect(defn["views"].pluck("id")).to eq(%w[home auto-cozinha auto-cozinha-2])
        board = site.dashboards.create!(name: "Casa", kind: "home", definition: defn)
        board.publish!(defn)
        pub = board.reload.published
        expect(Dashboards::Schema.errors(pub)).to eq([])
        auto = pub["views"][1]
        ids = auto["sections"].flat_map { |s| [ s["id"], *Dashboards::Resolver.flatten(s["widgets"]).pluck("id") ] }
        expect(ids).to all(start_with("auto-cozinha--"))
        expect(auto["badges"].pluck("bind")).to include(porta.id)
        expect(pub["views"][2]["sections"].size).to eq(1) # por aparelho, sem arrumar

        novo = pt(create(:device, site: site, area: cozinha, name: "Cafeteira"), "Cafeteira", writable: true, value: false)
        expect(board.reload.published["views"][1]["sections"].flat_map { _1["widgets"] }.pluck("bind")).to include(novo.id)

        frozen = Dashboards::AutoViews.freeze_view(board.definition, site, "auto-cozinha")
        expect(frozen["views"][1]).not_to have_key("auto")
        board.publish!(frozen)
        pt(create(:device, site: site, area: cozinha, name: "Forno"), "Forno", writable: true)
        expect(board.reload.published["views"][1]).to eq(frozen["views"][1])

        expect(Dashboards::AutoViews.errors({ "area" => 1 }, "v")).to be_present
        expect(Dashboards::AutoViews.errors({ "home" => true, "areas" => [ sala.id ] }, "v")).to eq([])
        gone = { "id" => "x", "title" => "X", "auto" => { "area" => SecureRandom.uuid }, "sections" => [] }
        expect(Dashboards::AutoViews.expand({ "views" => [ gone ] }, site)["views"].first["sections"].size).to eq(1)
      end
    end
  end

  describe "assistente (ideia 8)" do
    it "monta Início + cômodos escolhidos com o tema e cria o painel publicado" do
      within(tenant) do
        expect(Dashboards::Wizard.areas(site).map(&:name)).not_to include("Térreo")
        defn = Dashboards::Wizard.build(site, area_ids: [ cozinha.id, sala.id ], theme: "aurora", layout: "columns")
        expect(defn["views"].pluck("title")).to eq([ "Início", "Cozinha", "Sala" ])
        expect(defn["views"][0]["auto"]).to eq("home" => true, "areas" => [ cozinha.id, sala.id ])
        expect(defn["theme"]).to eq("key" => "aurora")
        cards = defn["views"][0]["sections"].flat_map { _1["widgets"] }.select { _1["type"] == "area_card" }
        expect(cards.pluck("area")).to contain_exactly(cozinha.id, sala.id)
        d = Dashboards::Wizard.create!(site, name: "", author: user, area_ids: Dashboards::Wizard.areas(site).map(&:id), layout: "devices")
        expect(d).to have_attributes(name: "Minha casa", version: 1, auto?: false)
        expect(d.definition["views"].first["auto"]).to eq("home" => true)
        expect(d.definition["views"][1]["auto"]).to include("arrange" => false)
      end
    end
  end

  describe "montagem por frase (ideia 3)" do
    def fake_ai!(answer, capabilities: %i[text structured])
      seen = []
      klass = Class.new(Ai::Providers::Base) do
        describe key: "eco", label: "Eco de teste", default_model: "eco-1", capabilities: capabilities, key_required: false
        define_method(:complete) do |model:, system:, user:, schema:, **|
          seen << { system: system, user: user, schema: schema }
          Ai::Providers::Base::Result.new(data: schema ? answer : "Claro! #{answer.to_json} pronto", usage: { input: 10, output: 5 })
        end
      end
      stub_const("Ai::Providers::Eco", klass)
      stub_const("Ai::PROVIDERS", Ai::PROVIDERS + %w[Eco])
      within(tenant) { AiAccount.find_or_create_by!(provider: "eco") }
      seen
    end

    let(:board) do
      within(tenant) do
        defn = { "schema_version" => 1, "views" => [ { "id" => "home", "title" => "Início", "sections" => [] } ] }
        site.dashboards.create!(name: "Casa", kind: "home", definition: defn).tap { _1.publish!(defn) }
      end
    end
    let(:answer) do
      { "title" => "Cozinha", "icon" => "home", "sections" => [
        { "title" => "Luzes", "widgets" => [ { "type" => "tile", "point" => luz.id, "label" => "Teto" }, { "type" => "foguete", "point" => fita.id },
                                             { "type" => "tile", "point" => "nao-existe" } ] },
        { "title" => "Câmera", "widgets" => [ { "type" => "gauge", "point" => cam.id } ] },
        { "title" => "Vazia", "widgets" => [] }
      ] }
    end

    it "gera um rascunho válido só com pontos do local, pela IA da instalação" do
      seen = fake_ai!(answer)
      result = within(tenant) { Dashboards::Compose.call(board, "monte a visão da cozinha com luzes e câmera", user: user) }
      view = result.definition["views"].last
      expect(view).to include("title" => "Cozinha", "area" => cozinha.id, "icon" => "home")
      widgets = view["sections"].flat_map { _1["widgets"] }
      expect(widgets.map { _1.slice("type", "bind", "label") }).to include({ "type" => "tile", "bind" => luz.id, "label" => "Teto" })
      expect(widgets.pluck("bind")).to contain_exactly(luz.id, fita.id, cam.id)
      expect(view["sections"].size).to eq(2)
      expect(result.dropped).to eq([ "nao-existe" ])
      expect(Dashboards::Schema.errors(result.definition)).to eq([])
      expect(seen.sole[:user]).to include("monte a visão da cozinha", luz.id)
      expect(seen.sole[:schema]).to be_present
      expect(within(tenant) { AiCall.sole }).to have_attributes(source: "painel", provider: "eco")

      # Mesma frase de novo substitui a visão de mesmo nome (sem duplicar ids).
      within(tenant) { board.update!(draft: result.definition) }
      again = within(tenant) { Dashboards::Compose.call(board, "de novo", user: user) }
      expect(again.definition["views"].size).to eq(2)
      expect(Dashboards::Schema.errors(again.definition)).to eq([])
    end

    it "sem saída estruturada lê o JSON do texto; erros viram mensagem" do
      fake_ai!(answer, capabilities: %i[text])
      result = within(tenant) { Dashboards::Compose.call(board, "cozinha", user: user) }
      expect(result.definition["views"].last["title"]).to eq("Cozinha")
      expect { within(tenant) { Dashboards::Compose.call(board, " ", user: user) } }.to raise_error(Dashboards::Compose::Error)
      fake_ai!({ "title" => "X", "sections" => [ { "title" => "a", "widgets" => [ { "type" => "tile", "point" => "zz" } ] } ] })
      expect { within(tenant) { Dashboards::Compose.call(board, "x", user: user) } }.to raise_error(Dashboards::Compose::Error, /não achou/)
    end

    it "sem provedor configurado avisa" do
      expect { within(tenant) { Dashboards::Compose.call(board, "cozinha", user: user) } }.to raise_error(Dashboards::Compose::Error, /IA/)
    end
  end
end
