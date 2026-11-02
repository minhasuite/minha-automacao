require "rails_helper"

# ondaA1: paridade com o HA nos grupos 1 e 2 (organização da casa,
# automações, templates, helpers, todo e calendário). Cada pacote numa seção.
RSpec.describe "ondaA1: paridade HA (organização e automações)" do
  let(:tenant) { create(:tenant) }
  let(:owner) { create(:user, tenant: tenant, role: "owner") }
  let(:site) { create(:site) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  describe "A1 andares" do
    let!(:terreo) { create(:area, site: site, name: "Térreo", kind: "floor", level: 0) }
    let!(:superior) { create(:area, site: site, name: "Superior", kind: "floor", level: 1) }
    let!(:sala) { create(:area, site: site, name: "Sala", parent: terreo) }
    let!(:canto) { create(:area, site: site, name: "Canto", parent: sala) }
    let!(:quarto) { create(:area, site: site, name: "Quarto", parent: superior) }
    let!(:luz_sala) { create(:point, site: site, device: create(:device, site: site, area: sala), name: "Luz", value: true) }
    let!(:luz_canto) { create(:point, site: site, device: create(:device, site: site, area: canto), name: "Abajur", value: true) }
    let!(:luz_quarto) { create(:point, site: site, device: create(:device, site: site, area: quarto), name: "Luz do quarto", value: true) }

    it "nível, andar de cada área (pela hierarquia) e rótulo do nível" do
      expect(canto.floor_area).to eq(terreo)
      expect(terreo.subtree_ids).to contain_exactly(terreo.id, sala.id, canto.id)
      expect([ terreo, superior, build(:area, kind: "floor", level: -1) ].map(&:level_label)).to eq([ "Térreo", "1º andar", "Subsolo 1" ])
      expect(build(:area, site: site, level: 999)).not_to be_valid
    end

    it "consulta `floor=` pega o andar inteiro (e serve ao comando por consulta)" do
      expect(Points::Query.new(site).call("floor=Térreo").map(&:id)).to contain_exactly(luz_sala.id, luz_canto.id)
      expect(Points::Query.new(site).call("floor=#{superior.id}").map(&:id)).to eq([ luz_quarto.id ])
      expect(Points::Query.new(site).call("floor=Inexistente")).to be_empty
    end

    it "voz: \"apague o térreo\" desliga só o andar" do
      r = Assist.call(site: site, user: owner, text: "apague o térreo")
      expect(r["text"]).to start_with("Desliguei")
      expect([ luz_sala, luz_canto, luz_quarto ].map { |p| p.reload.value }).to eq([ false, false, true ])
    end

    it "painel automático agrupa as áreas por andar, na ordem do nível" do
      views = Dashboards::Generator.new(site).call["views"]
      titles = views.first["sections"].map { |s| s["title"] }
      expect(titles & [ "Térreo", "Superior" ]).to eq([ "Térreo", "Superior" ])
    end

    it "importa os andares do HA e o alvo `floor_id` vira consulta" do
      files = { "floor_registry" => { "data" => { "floors" => [ { "floor_id" => "andar_1", "name" => "Andar de cima", "level" => 1 } ] } },
                "area_registry" => { "data" => { "areas" => [ { "id" => "suite", "name" => "Suíte", "floor_id" => "andar_1" } ] } } }
      Integrations::HomeAssistantImport.new(site, files).call
      floor = site.areas.find_by!(name: "Andar de cima")
      expect(floor).to have_attributes(kind: "floor", level: 1)
      expect(site.areas.find_by!(name: "Suíte").parent).to eq(floor)

      importer = Blueprints::HaImport.new("", nil, entities: true, areas: { "floor:andar_1" => "Andar de cima" })
      bp = importer.convert(Blueprints::HaImport.as_blueprint("script", "X", { "sequence" => [ { "action" => "light.turn_off", "target" => { "floor_id" => "andar_1" } } ] }))
      expect(bp["definition"]["actions"]).to eq([ { "type" => "command_query", "query" => "floor=\"Andar de cima\" capability=onoff", "command" => "off" } ])
    end
  end

  describe "A2 rótulos e categorias" do
    let(:room) { create(:area, site: site, name: "Sala") }
    let(:dev) { create(:device, site: site, area: room) }
    let!(:lamp) { create(:point, site: site, device: dev, name: "Luz", value: true) }
    let!(:other) { create(:point, site: site, device: create(:device, site: site), name: "Outra", value: true) }

    it "rótulo em ponto, aparelho, área e cena; o do aparelho e o da área valem para os pontos na consulta" do
      dev.update!(label_list: "Iluminação, Noite")
      room.update!(label_list: "térreo")
      other.update!(label_list: "externo")
      scene = site.scenes.create!(name: "Cinema", label_list: "noite", category: "  Lazer ", items: [ { "point_id" => lamp.id, "command" => "off" } ])
      expect(dev.reload.label_names).to eq(%w[iluminação noite])
      expect(scene.reload).to have_attributes(label_list: "noite", category: "Lazer")
      q = ->(text) { Points::Query.new(site).call(text).map(&:name) }
      expect(q.call("tag=iluminação")).to eq([ "Luz" ])
      expect(q.call("tag=térreo")).to eq([ "Luz" ])
      expect(q.call("tag=externo")).to eq([ "Outra" ])
      expect(Scene.labeled("noite")).to eq([ scene ])
      expect(Scene.labels_in(site.scenes)).to eq([ "noite" ])
    end

    it "modelo novo ganha rótulo só com `include Labelable` (plugin falso)" do
      fake = Class.new(ApplicationRecord) do
        self.table_name = "scenes"
        acts_as_tenant :tenant
        include Labelable
        def self.name = "TesteRotulado"
      end
      stub_const("TesteRotulado", fake)
      rec = TesteRotulado.create!(site_id: site.id, name: "Teste rótulo", items: [])
      rec.update!(label_list: "a, b, a")
      expect(rec.reload.label_names).to eq(%w[a b])
      expect(TesteRotulado.labeled("b").pluck(:id)).to eq([ rec.id ])
    end

    it "helper com categoria e rótulos pelo formulário" do
      point = HelperTypes.build(site, HelperTypes.plugin("toggle"))
      expect(HelperTypes.save(point, "name" => "Teste férias", "category" => "Modos", "label_list" => "casa")).to be true
      expect(point.reload).to have_attributes(category: "Modos", label_list: "casa")
    end
  end

  describe "A3 apelidos e Expor" do
    let(:room) { create(:area, site: site, name: "Sala", aliases: [ "living" ]) }
    let!(:lamp) { create(:point, site: site, device: create(:device, site: site, area: room), name: "Luz", value: false, aliases: [ " abajur ", "Abajur", "leitura" ]) }

    it "apelido de ponto e de área valem para a voz e a busca; tirar do Assist esconde da voz" do
      expect(lamp.aliases).to eq(%w[abajur leitura])
      expect(Assist.call(site: site, user: owner, text: "ligar a leitura")["text"]).to eq("Liguei Luz.")
      expect(Assist.call(site: site, user: owner, text: "desligar o living")["text"]).to eq("Desliguei Luz.")
      assist = Exposure.targets(site).find { |t| t.key == "assist" }
      expect(assist.set!(lamp, false)).to be_nil
      expect(assist.exposed?(lamp.reload)).to be false
      expect(Assist.find_points(site, "abajur")).to be_empty
    end

    it "assistente novo entra na tela só pelo registro (plugin falso)" do
      fake = Class.new(Exposure::Target) do
        def key = "teste"
        def title = "Teste"
        def icon = "cube"
        def exposed?(point) = point.expose.to_h["teste"] == true
        def set!(point, on, confirm: false) = point.update!(expose: point.expose.to_h.merge("teste" => on)) && nil
      end
      stub_const("Exposure::Teste", fake)
      stub_const("Exposure::PLUGINS", [ *Exposure::PLUGINS, "Teste" ])
      t = Exposure.targets(site).find { |x| x.key == "teste" }
      expect(t.title).to eq("Teste")
      t.set!(lamp, true)
      expect(t.exposed?(lamp.reload)).to be true
    end
  end
end
