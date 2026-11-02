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
end
