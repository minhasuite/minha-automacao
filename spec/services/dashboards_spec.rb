require "rails_helper"

RSpec.describe "Dashboards (serviços)" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:sala) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let!(:garagem) { within(tenant) { create(:area, site: site, name: "Garagem") } }
  let!(:lamp_dev) { within(tenant) { create(:device, site: site, area: sala, name: "Lâmpada Sala") } }
  let!(:lamp) { within(tenant) { create(:point, device: lamp_dev, name: "Luz do teto", value: true) } }
  let!(:plug) { within(tenant) { create(:device, site: site, area: sala, name: "Tomada TV") } }
  let!(:tv) { within(tenant) { create(:point, device: plug, name: "Painel TV", value: false) } }
  let!(:power) { within(tenant) { create(:point, device: plug, name: "Potência", capability: "measure", unit: "W", device_class: "power", value: 120.5) } }
  let!(:volts) { within(tenant) { create(:point, device: plug, name: "Tensão", capability: "measure", unit: "V", device_class: "voltage", value: 220) } }
  let!(:gate_dev) { within(tenant) { create(:device, site: site, area: garagem, name: "Portão") } }
  let!(:gate) { within(tenant) { create(:point, device: gate_dev, name: "Portão", risk: "critical", value: false) } }

  def all_widgets(defn) = defn["views"].flat_map { |v| Array(v["badges"]) + v["sections"].flat_map { |s| s["widgets"] } }

  describe Dashboards::Schema do
    let(:valid) do
      { "schema_version" => 1, "views" => [ { "id" => "v1", "title" => "Casa", "sections" => [ { "id" => "s1", "widgets" => [
        { "id" => "w1", "type" => "tile", "bind" => "sala.luz", "span" => { "mobile" => 12, "desktop" => 4 }, "visible_if" => { "role" => %w[owner resident], "time" => { "after" => "18:00" } } },
        { "id" => "w2", "type" => "stat", "query" => { "capability" => "onoff", "state" => "on" }, "aggregate" => "count" }
      ] } ] } ] }
    end

    it "aceita a definição da §6.1 e aponta cada erro" do
      expect(described_class.errors(valid)).to eq([])
      expect(described_class.errors([])).to eq([ "precisa ser um objeto JSON" ])
      expect(described_class.errors({ "schema_version" => 2, "views" => [] }).join).to include("schema_version", "views")

      bad = valid.deep_dup
      w = bad["views"][0]["sections"][0]["widgets"]
      w << { "id" => "w1", "type" => "foguete" }
      w << { "id" => "w3", "type" => "tile", "span" => { "mobile" => 13 }, "visible_if" => { "role" => [ "rei" ], "time" => { "after" => "25:00" }, "state" => {}, "x" => 1 } }
      w << { "id" => "w4", "type" => "stat", "aggregate" => "moda" }
      w << { "id" => "w5", "type" => "chart", "binds" => Array.new(9, "a"), "range" => "1y", "tap" => "pular", "color" => "rosa", "min" => "0", "features" => [ "voar" ] }
      w << { "id" => "w6", "type" => "query_list", "query" => { "capability" => "foguete", "state" => "meio", "y" => 1 } }
      w << "texto"
      errors = described_class.errors(bad).join("\n")
      expect(errors).to include("id repetido", "tipo desconhecido", "bind obrigatório", "span.mobile", "visible_if.role", "visible_if.time",
                                "visible_if.state", "chave desconhecida", "aggregate inválido", "stat precisa de bind ou query", "binds precisa",
                                "range inválido", "tap inválido", "color inválida", "min precisa", "features inválidas", "query.capability",
                                "query.state", "widget precisa ser um objeto")
    end
  end

  describe Dashboards::Generator do
    it "gera Início com luzes, o que está ligado, consumo, segurança e áreas, e uma view por área sem tensão" do
      defn = within(tenant) { described_class.call(site) }
      expect(Dashboards::Schema.errors(defn)).to eq([])
      home = defn["views"].first
      expect(home["title"]).to eq("Início")
      expect(home["sections"].map { |s| s["title"] }).to eq([ "Luzes", "Agora", "Consumo", "Segurança", "Áreas" ])
      expect(home["sections"][0]["widgets"].map { |w| w["bind"] }).to eq([ lamp.id ])
      expect(home["sections"][0]["widgets"][0]["color"]).to eq("amber")
      expect(home["sections"][3]["widgets"].map { |w| w["bind"] }).to eq([ gate.id ])
      expect(defn["views"].map { |v| v["title"] }).to eq([ "Início", "Garagem", "Sala" ])
      binds = all_widgets(defn).flat_map { |w| [ w["bind"], *w["binds"] ] }
      expect(binds).to include(power.id, tv.id)
      expect(binds).not_to include(volts.id)
      expect(within(tenant) { described_class.call(site) }).to eq(defn) # ids estáveis
    end
  end

  describe Dashboards::Resolver do
    let(:dashboard) { within(tenant) { Dashboard.ensure_for(site).first } }

    it "resolve valores, contagens, área, alertas e esconde por papel" do
      within(tenant) do
        site.scenes.create!(name: "Sair", items: [ { point_id: gate.id, command: "toggle" } ])
        AlertRule.create!(point: tv, name: "TV ligada", value: true)
        tv.report!(true)
        r = described_class.new(dashboard, role: "owner").call
        home = r["views"].first
        badge = home["badges"].find { |b| b["id"] == "b-on" }
        expect(badge["data"]).to include("value" => 2, "text" => "2")
        expect(home["badges"].find { |b| b["id"] == "b-power" }["data"]["text"]).to eq("120,5 W")
        list = home["sections"].flat_map { |s| s["widgets"] }.find { |w| w["id"] == "w-home-on" }
        expect(list["data"]["point_ids"]).to contain_exactly(lamp.id, tv.id)
        expect(list["deps"]).to include(gate.id)
        expect(r["points"][lamp.id]).to include("text" => "Ligado", "on" => true, "can_command" => true)
        expect(r["points"][gate.id]).to include("risk" => "critical")
        alerts = home["sections"].flat_map { |s| s["widgets"] }.find { |w| w["type"] == "alerts" }
        expect(alerts["data"]["alerts"].first).to include("title" => "TV ligada", "can_ack" => true)
        expect(alerts["deps"]).to eq([ tv.id ])
        area = home["sections"].flat_map { |s| s["widgets"] }.find { |w| w["type"] == "area_card" && w["area"] == sala.id }
        expect(area["data"]).to include("on" => 2, "power" => 120.5, "view_id" => "a-#{sala.id}")

        guest = described_class.new(dashboard, role: "guest").call
        expect(guest["points"][gate.id]["can_command"]).to be false
        expect(guest["can_edit"]).to be false
        scenes = guest["views"].first["sections"].flat_map { |s| s["widgets"] }.find { |w| w["type"] == "scene_bar" }
        expect(scenes["data"]["scenes"].first).to include("can_activate" => false, "confirm" => true)
      end
    end

    it "aplica visible_if (papel, estado, qualidade, hora), gauge, stat e query por área e etiqueta" do
      within(tenant) do
        tag = Tag.create!(name: "iluminacao")
        Tagging.create!(tag: tag, taggable: tv)
        defn = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "T", "sections" => [ { "id" => "s", "widgets" => [
          { "id" => "a", "type" => "tile", "bind" => lamp.key, "visible_if" => { "role" => [ "owner" ] } },
          { "id" => "b", "type" => "tile", "bind" => lamp.id, "visible_if" => { "state" => { "point" => gate.id, "is" => [ true ] } } },
          { "id" => "c", "type" => "tile", "bind" => lamp.id, "visible_if" => { "quality" => [ "unavailable" ] } },
          { "id" => "d", "type" => "tile", "bind" => lamp.id, "visible_if" => { "time" => { "after" => "22:00", "before" => "06:00" } } },
          { "id" => "e", "type" => "gauge", "bind" => power.id, "max" => 241 },
          { "id" => "f", "type" => "stat", "bind" => power.id },
          { "id" => "g", "type" => "stat", "query" => { "area" => sala.id, "device_class" => "power" }, "aggregate" => "avg" },
          { "id" => "h", "type" => "query_list", "query" => { "tag" => "iluminacao" } },
          { "id" => "i", "type" => "tile", "bind" => "nao.existe" },
          { "id" => "j", "type" => "area_card", "area" => SecureRandom.uuid },
          { "id" => "k", "type" => "stat", "query" => { "capability" => "measure" }, "aggregate" => "max" },
          { "id" => "l", "type" => "stat", "query" => { "capability" => "measure" }, "aggregate" => "min" },
          { "id" => "m", "type" => "heading", "title" => "Oi" }
        ] } ] } ] }
        travel_to(Time.zone.parse("2026-10-29 12:00 -03:00")) do
          r = described_class.new(dashboard, role: "resident", definition: defn)
          widgets = r.call["views"][0]["sections"][0]["widgets"].index_by { |w| w["id"] }
          expect(widgets).not_to have_key("a")
          expect(widgets.values_at("b", "c", "d").map { |w| w["visible"] }).to eq([ false, false, false ])
          expect(widgets["e"]["data"]).to include("ratio" => 0.5, "max" => 241.0)
          expect(widgets["f"]["data"]["text"]).to eq("120.5 W").or eq("120,5 W")
          expect(widgets["g"]["data"]["value"]).to eq(120.5)
          expect(widgets["h"]["data"]["point_ids"]).to eq([ tv.id ])
          expect(widgets["i"]["data"]["missing"]).to be true
          expect(widgets["j"]["data"]["missing"]).to be true
          expect(widgets["k"]["data"]["value"]).to eq(220)
          expect(widgets["l"]["data"]["value"]).to eq(120.5)
          expect(r.widget("e")["id"]).to eq("e")
          expect(r.widget("a")).to be_nil
          expect(r.widget("zzz")).to be_nil
        end
      end
    end
  end

  describe Dashboards::Editor do
    it "cria, altera, move e remove view, seção e widget" do
      e = described_class.new({})
      v = e.add_view(title: "Sala", icon: "home")
      s = e.add_section(v, title: "Luzes")
      w1 = e.add_widget(s, { "type" => "tile", "bind" => "x" })
      w2 = e.add_widget(s, { "type" => "heading", "title" => "Oi" })
      e.move("widget", w2, "up")
      e.move("widget", w2, "up") # já é o primeiro
      expect(e.section(s)["widgets"].map { |w| w["id"] }).to eq([ w2, w1 ])
      e.update_widget(w1, { "type" => "tile", "bind" => "y" })
      expect(e.widget(w1)).to eq("id" => w1, "type" => "tile", "bind" => "y")
      e.update_view(v, title: "Sala de estar")
      e.update_section(s, title: "", span: { "desktop" => 6 })
      expect(e.view(v)["title"]).to eq("Sala de estar")
      expect(e.section(s)).to include("span" => { "desktop" => 6 })
      expect(e.section(s)).not_to have_key("title")
      v2 = e.add_view(title: "")
      e.move("view", v2, "up")
      expect(e.definition["views"].map { |x| x["title"] }).to eq([ "Nova view", "Sala de estar" ])
      e.move("section", s, "down")
      e.remove("widget", w2)
      e.remove("section", s)
      e.remove("view", v2)
      expect(e.definition["views"].size).to eq(1)
      expect { e.remove("widget", "nada") }.to raise_error(KeyError)
      expect { e.view("nada") }.to raise_error(KeyError)
    end
  end

  describe Dashboard do
    it "nasce automático, publica, volta versão e valida o JSON" do
      within(tenant) do
        d = described_class.ensure_for(site).first
        expect(d).to have_attributes(auto: true, site_default: true, version: 0)
        expect(described_class.ensure_for(site)).to eq([ d ])
        expect(d.published["views"].first["title"]).to eq("Início")

        d.update!(draft: d.working_draft.merge("views" => [ { "id" => "v", "title" => "Só uma", "sections" => [] } ]))
        d.publish!
        expect(d.reload).to have_attributes(auto: false, version: 1, draft: nil)
        expect(d.published["views"].first["title"]).to eq("Só uma")
        d.publish!(d.definition.merge("views" => [ { "id" => "v", "title" => "Outra", "sections" => [] } ]))
        d.revert!(1)
        expect(d.reload.version).to eq(3)
        expect(d.definition["views"].first["title"]).to eq("Só uma")
        expect(d.versions.map(&:version)).to eq([ 3, 2, 1 ])
        expect { d.publish!(nil) }.to raise_error(ArgumentError)

        d.draft = { "schema_version" => 1 }
        d.roles = [ "rei" ]
        expect(d).not_to be_valid
        expect(d.errors.full_messages.join).to include("views", "papel")
        d.roles = []
        expect(d.visible_to?("guest")).to be true
        d.roles = [ "resident" ]
        expect([ d.visible_to?("guest"), d.visible_to?("owner"), d.visible_to?("resident") ]).to eq([ false, true, true ])
      end
    end

    it "avisa os dashboards quando o ponto muda (stream do local, só o id)" do
      within(tenant) do
        expect { lamp.report!(false) }.to have_broadcasted_to("#{site.to_gid_param}:points")
          .with(a_string_including(%(action="point_changed"), %(target="#{lamp.id}")))
      end
    end
  end
end
