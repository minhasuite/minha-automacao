require "rails_helper"

# Modelos de card declarativos (P1.3), predefinições como dado (P2.2),
# exportar/importar como pacote (P2.3), galeria de estilos de card (ideia 19)
# e a biblioteca de painéis prontos (ideia 20).
RSpec.describe "Modelos de card e painéis prontos como dado" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:sala) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let!(:cozinha) { within(tenant) { create(:area, site: site, name: "Cozinha") } }
  let!(:aparelho) { within(tenant) { create(:device, site: site, area: sala, name: "Quadro") } }
  let!(:luz) { within(tenant) { create(:point, device: aparelho, name: "Teto", value: true) } }
  let!(:abajur) { within(tenant) { create(:point, device: aparelho, name: "Abajur", value: false) } }
  let!(:porta) { within(tenant) { create(:point, device: aparelho, name: "Porta", capability: "contact", value: true) } }
  let!(:fita) { within(tenant) { create(:point, device: aparelho, name: "Fita", value: false, quality: "unavailable") } }
  let(:own_template) do
    { key: "porta-sala", name: "Porta", layout: "row",
      params: [ { "key" => "porta", "label" => "Porta", "kind" => "point", "required" => true }, { "key" => "rotulo", "label" => "Rótulo", "kind" => "text" } ],
      slots: { "title" => "{{ vars.rotulo | default: vars.porta.name }}", "value" => "{{ vars.porta.text }}",
               "tone" => [ { "when" => { "state" => { "point" => "{{ vars.porta }}", "is" => "true" } }, "value" => "danger" } ],
               "subtitle" => { "query" => { "capability" => "onoff", "state" => "on" }, "aggregate" => "count", "label" => { "one" => "%{count} luz", "other" => "%{count} luzes" } },
               "tap" => { "action" => "more_info", "point" => "{{ vars.porta }}" } } }
  end

  def login = post("/entrar", params: { email: user.email, password: "12345678" })
  def flat(res) = Dashboards::Resolver.flatten(res["views"].flat_map { |v| [ *v["badges"], *v["sections"].flat_map { _1["widgets"] } ] })
  def defn(*widgets, **extra) = { "schema_version" => 1, "views" => [ { "id" => "home", "title" => "Início", "sections" => [ { "id" => "s1", "widgets" => widgets } ] } ] }.merge(extra.stringify_keys)

  def board(*widgets, **extra)
    d = defn(*widgets, **extra)
    within(tenant) { site.dashboards.create!(name: "Teste", kind: "custom", definition: d).tap { _1.publish!(d, author: user) } }
  end

  def resolve(d, role: "owner") = within(tenant) { Dashboards::Resolver.new(d, role: role).call }


  describe "modelo embutido do cartão de área" do
    it "resolve igual ao cartão de área: título, pílulas do padrão do local, toque para a área" do
      d = board({ "id" => "t1", "type" => "template", "template" => "area", "vars" => { "area" => sala.id } }, { "id" => "ac", "type" => "area_card", "area" => sala.id })
      res = resolve(d)
      tpl = flat(res).find { _1["id"] == "t1" }
      card = flat(res).find { _1["id"] == "ac" }
      expect(tpl["data"]).to include("layout" => "mosaic", "title" => "Sala", "icon" => "view-boards")
      expect(tpl["data"]["facts"].map { _1["text"] }).to eq(card["data"]["facts"].map { _1["text"] })
      expect(tpl["data"]["facts"].first["url"]).to include("/w/t1/pontos")
      expect(tpl["data"]["tap"]).to include("action" => "navigate", "path" => "/areas/#{sala.id}")
      expect(tpl["deps"]).to include(luz.id, porta.id)
    end

    it "sem a área obrigatória avisa o que falta, sem toque" do
      res = resolve(board({ "id" => "t1", "type" => "template", "template" => "area" }))
      data = flat(res).first["data"]
      expect(data["missing_vars"]).to eq([ "Área" ])
      expect(data).not_to have_key("tap")
    end

    it "modelo que sumiu aparece como sumido" do
      data = flat(resolve(board({ "id" => "t1", "type" => "template", "template" => "nao-existe" }))).first["data"]
      expect(data).to include("missing" => true, "template" => "nao-existe")
    end

    it "a lista de um item (ideia 14) também vale para o modelo" do
      d = board({ "id" => "t1", "type" => "template", "template" => "area", "vars" => { "area" => sala.id } })
      login
      get "/paineis/#{d.id}/w/t1/pontos", params: { item: "on" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Teto")
    end
  end

  describe "modelo do local (Liquid, consulta, regra e toque)" do
    let!(:template) { within(tenant) { site.card_templates.create!(own_template) } }

    it "resolve os espaços no servidor e o toque só pelo registro de ações" do
      d = board({ "id" => "p1", "type" => "template", "template" => "porta-sala", "vars" => { "porta" => porta.id } })
      data = flat(resolve(d)).first["data"]
      expect(data).to include("layout" => "row", "title" => "Porta", "tone" => "danger", "subtitle" => "1 luz", "version" => 1)
      expect(data["value"]).to be_present
      expect(data["tap"]).to include("action" => "more_info", "point_id" => porta.id)
      within(tenant) { porta.update!(value: false) }
      expect(flat(resolve(d)).first["data"]).not_to have_key("tone")
    end

    it "mudar desenho ou espaços sobe a versão" do
      within(tenant) { template.update!(name: "Outra") }
      expect(template.reload.version).to eq(1)
      within(tenant) { template.update!(layout: "chip") }
      expect(template.reload.version).to eq(2)
    end

    it "valida desenho, espaços, marcadores, Liquid e ação" do
      bad = within(tenant) do
        site.card_templates.new(key: "x1", name: "X", layout: "carrossel", params: [ { "key" => "a", "kind" => "cor" } ],
                                slots: { "title" => "{{ vars.b ", "outro" => "x", "tap" => { "action" => "explodir" }, "tone" => "roxo" })
      end
      expect(within(tenant) { bad.valid? }).to be(false)
      msgs = bad.errors.full_messages.join(" | ")
      expect(msgs).to include("layout", "kind", "espaço desconhecido")
      errs = Dashboards::CardTemplates.errors(bad.to_template)
      expect(errs.join(" ")).to include("Liquid", "tom")
      expect(Dashboards::CardTemplates.errors(own_template.deep_stringify_keys.merge("slots" => { "title" => "{{ vars.nada.name }}" })).join).to include("nada")
    end

    it "todos os desenhos aparecem no painel da web" do
      %w[mosaic tile row chip stat].each { |l| within(tenant) { site.card_templates.create!(own_template.merge(key: "l-#{l}", layout: l)) } }
      widgets = %w[mosaic tile row chip stat].map { |l| { "id" => "w-#{l}", "type" => "template", "template" => "l-#{l}", "vars" => { "porta" => porta.id, "rotulo" => "Rótulo #{l}" } } }
      d = board(*widgets)
      login
      get "/paineis/#{d.id}"
      expect(response).to have_http_status(:ok)
      %w[mosaic tile row chip stat].each { |l| expect(response.body).to include("Rótulo #{l}") }
      expect(response.body).to include("dw-gesture")
    end

    it "o app recebe o mesmo data pela API" do
      d = board({ "id" => "p1", "type" => "template", "template" => "porta-sala", "vars" => { "porta" => porta.id } })
      get "/api/v1/dashboards/#{d.id}", headers: auth_headers(user)
      w = data["views"][0]["sections"][0]["widgets"][0]
      expect(w["data"]).to include("layout" => "row", "title" => "Porta")
      expect(data["points"]).to have_key(porta.id)
    end

    it "o widget valida a chave e as entradas no Schema" do
      errs = Dashboards::Schema.errors(defn({ "id" => "x", "type" => "template", "template" => "A B", "vars" => { "a" => { "b" => 1 } } }))
      expect(errs.join(" ")).to include("template", "vars")
    end
  end

  describe "editor de modelos (web)" do
    before { login }

    it "lista os embutidos, duplica o cartão de área e edita com prévia ao vivo" do
      get "/locais/#{site.id}/modelos-de-card"
      expect(response.body).to include("Cartão de área", "Ponto em linha")
      post "/locais/#{site.id}/modelos-de-card/duplicar", params: { key: "area" }
      copy = within(tenant) { site.card_templates.find_by!(key: "area-2") }
      expect(copy.slots["facts"]).to eq({ "from" => "area_defaults", "scope" => { "area" => "{{ vars.area }}" } })
      expect(response).to redirect_to("/modelos-de-card/#{copy.id}/editar")
      get "/modelos-de-card/#{copy.id}/editar"
      expect(response.body).to include("tpl_preview", "Sala") # prévia de abertura com a primeira área

      patch "/locais/#{site.id}/modelos-de-card/previa",
            params: { card_template: { name: "X", layout: "stat", slot_title: "Luzes {{ vars.area.name }}", slot_value: '{"query": {"capability": "onoff", "state": "on"}}',
                                       params: { "0" => { key: "area", label: "Área", kind: "area", required: "1" } }, sample: { area: cozinha.id } } }
      expect(response.body).to include("<turbo-frame id=\"tpl_preview\"", "Luzes Cozinha")

      post "/locais/#{site.id}/modelos-de-card/previa", params: { card_template: { name: "X", layout: "stat", slot_value: "{quebrado" } }
      expect(response.body).to include("JSON")

      patch "/modelos-de-card/#{copy.id}", params: { card_template: { name: "Área compacta", layout: "chip", slot_title: "{{ vars.area.name }}",
                                                                     params: { "0" => { key: "area", label: "Área", kind: "area", required: "1" } } } }
      expect(copy.reload).to have_attributes(name: "Área compacta", layout: "chip", version: 2)
      patch "/modelos-de-card/#{copy.id}", params: { card_template: { name: "Y", layout: "chip", slot_tap: "{nada" } }
      expect(response).to have_http_status(:unprocessable_content)

      delete "/modelos-de-card/#{copy.id}"
      expect(within(tenant) { site.card_templates.exists?(copy.id) }).to be(false)
    end

    it "cria um modelo novo e põe no painel pelo formulário do widget" do
      get "/locais/#{site.id}/modelos-de-card/novo"
      expect(response).to have_http_status(:ok)
      post "/locais/#{site.id}/modelos-de-card", params: { card_template: { name: "Luz", key: "luz-x", layout: "tile", slot_title: "{{ vars.luz.name }}", slot_value: "{{ vars.luz.text }}",
                                                                           params: { "0" => { key: "luz", label: "Luz", kind: "point" } } } }
      tpl = within(tenant) { site.card_templates.find_by!(key: "luz-x") }
      expect(response).to redirect_to("/modelos-de-card/#{tpl.id}/editar")
      post "/locais/#{site.id}/modelos-de-card", params: { card_template: { name: "", key: "luz-x", layout: "x" } }
      expect(response).to have_http_status(:unprocessable_content)

      d = board({ "id" => "h", "type" => "heading", "title" => "Oi" })
      get "/paineis/#{d.id}/editar"
      expect(response.body).to include("widget[template]", "widget[vars][luz]")
      patch "/paineis/#{d.id}/rascunho", params: { op: "add_widget", target: "s1", view_id: "home", widget: { type: "template", template: "luz-x", vars: { luz: luz.id, area: "" } } }
      w = d.reload.draft["views"][0]["sections"][0]["widgets"].last
      expect(w).to include("type" => "template", "template" => "luz-x", "vars" => { "luz" => luz.id })
    end

    it "exporta o modelo com o ponto fixo virando entrada, e importa no outro lado" do
      tpl = within(tenant) do
        site.card_templates.create!(key: "fixo", name: "Fixo", layout: "row", params: [],
                                    slots: { "title" => "Porta", "tone" => [ { "when" => { "state" => { "point" => porta.id, "is" => "true" } }, "value" => "warn" } ] })
      end
      get "/locais/#{site.id}/modelos-de-card/exportar", params: { key: tpl.key }
      manifest = response.parsed_body
      item = manifest["items"].first
      expect(item["type"]).to eq("card_template")
      expect(item["params"]).to include(hash_including("kind" => "point", "label" => "Porta"))
      expect(item["slots"].to_json).not_to include(porta.id)
      expect(within(tenant) { Packages.errors(manifest, site) }).to be_empty

      other = within(tenant) { create(:site, name: "Praia") }
      post "/locais/#{other.id}/paineis/prontos/importar", params: { file: Rack::Test::UploadedFile.new(StringIO.new(manifest.to_json), "application/json", original_filename: "fixo.json") }
      expect(response).to redirect_to("/locais/#{other.id}/modelos-de-card")
      expect(within(tenant) { other.card_templates.find_by(key: "fixo") }).to have_attributes(source: "package:fixo")
    end
  end

  describe "predefinições como dado (P2.2) e a biblioteca (ideia 20)" do
    it "cada painel da biblioteca é um pacote válido e as predefinições aparecem na tela" do
      Dashboards::Presets.library_manifests.each { |m| expect(within(tenant) { Packages.errors(m, site) }).to be_empty, m["key"] }
      login
      get "/locais/#{site.id}/paineis/prontos"
      expect(response.body).to include("Energia", "Casa minimalista", "Tablet da cozinha", "Segurança", "Saúde da casa", "Biblioteca")
    end

    it "cria a casa minimalista com as áreas escolhidas; área opcional vazia some" do
      login
      get "/locais/#{site.id}/paineis/prontos/casa-minimalista"
      expect(response.body).to include("Primeira área")
      post "/locais/#{site.id}/paineis/prontos/casa-minimalista", params: { preset: { name: "Minha casa", area1: sala.id, area2: cozinha.id } }
      d = within(tenant) { site.dashboards.find_by!(name: "Minha casa") }
      widgets = d.definition["views"][0]["sections"][0]["widgets"]
      expect(widgets.map { _1["vars"]["area"] }).to eq([ sala.id, cozinha.id ])
      expect(d.definition["card_style"]).to eq("minimalista")
      post "/locais/#{site.id}/paineis/prontos/casa-minimalista", params: { preset: { name: "Sem área" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Primeira área")
    end

    it "saúde da casa usa o padrão do campo vazio" do
      preset = within(tenant) { Dashboards::Presets.find(site, "saude-da-casa") }
      definition = within(tenant) { preset.build(site, {}) }
      list = definition["views"][0]["sections"][0]["widgets"].find { _1["id"] == "sd-bateria" }
      expect(list["query"]["below"]).to eq(20)
      expect(Dashboards::Schema.errors(definition)).to be_empty
    end

    it "item preset de pacote: valida pelo Schema depois de trocar os marcadores e cria pelas entradas" do
      manifest = { "format" => 1, "key" => "luzes", "name" => "Luzes", "version" => "1.0.0",
                   "items" => [ { "type" => "preset", "key" => "sala", "name" => "Sala", "fields" => [ { "key" => "luz", "kind" => "point", "required" => true, "label" => "Luz", "filter" => { "capability" => "onoff" } } ],
                                  "definition" => defn({ "id" => "t", "type" => "tile", "bind" => "{{ fields.luz }}" }) } ] }
      bad = manifest.deep_dup.tap { _1["items"][0]["definition"] = defn({ "id" => "t", "type" => "tile", "bind" => "{{ fields.outra }}" }) }
      expect(within(tenant) { Packages.errors(bad, site) }.join).to include("outra")
      package = within(tenant) { Packages.install!(site, manifest, "arquivo:luzes.json") }
      preset = within(tenant) { Dashboards::Presets.find(site, "luzes--sala") }
      expect(preset.package).to eq(package)
      expect(preset.fields.first.filter.call(luz)).to be(true)
      expect(preset.fields.first.filter.call(porta)).to be(false)
      dash, errors = within(tenant) { Dashboards::Presets.create!(site, preset, { "luz" => luz.id }, author: user) }
      expect(errors).to be_empty
      expect(dash.definition["views"][0]["sections"][0]["widgets"][0]["bind"]).to eq(luz.id)
    end
  end

  describe "exportar o painel como pacote (P2.3)" do
    it "pontos e áreas viram entradas, o modelo do local vai junto e o outro lado importa mapeando" do
      within(tenant) { site.card_templates.create!(own_template) }
      d = board({ "id" => "t", "type" => "tile", "bind" => luz.id }, { "id" => "g", "type" => "group", "binds" => [ luz.id, abajur.id ] },
                { "id" => "a", "type" => "area_card", "area" => sala.id }, { "id" => "p", "type" => "template", "template" => "porta-sala", "vars" => { "porta" => porta.id } })
      login
      get "/paineis/#{d.id}/exportar"
      manifest = response.parsed_body
      expect(manifest["items"].map { _1["type"] }).to eq(%w[card_template preset])
      preset = manifest["items"].last
      expect(preset["fields"].map { _1["kind"] }).to contain_exactly("point", "point", "point", "area")
      expect(preset["definition"].to_json).not_to include(luz.id, sala.id)
      expect(within(tenant) { Packages.errors(manifest, site) }).to be_empty

      other = within(tenant) { create(:site, name: "Praia") }
      outra = within(tenant) { create(:point, device: create(:device, site: other, name: "Q"), name: "Luz da praia") }
      post "/locais/#{other.id}/paineis/prontos/importar", params: { file: Rack::Test::UploadedFile.new(StringIO.new(manifest.to_json), "application/json", original_filename: "teste.json") }
      key = "#{manifest['key']}--#{preset['key']}"
      expect(response).to redirect_to("/locais/#{other.id}/paineis/prontos/#{key}")
      luz_field = preset["fields"].find { _1["label"] == "Teto" }["key"]
      post "/locais/#{other.id}/paineis/prontos/#{key}", params: { preset: { name: "Praia", luz_field => outra.id } }
      novo = within(tenant) { other.dashboards.find_by!(name: "Praia") }
      expect(novo.definition["views"][0]["sections"][0]["widgets"].map { _1["id"] }).to eq(%w[t g])
      expect(novo.definition["views"][0]["sections"][0]["widgets"][0]["bind"]).to eq(outra.id)
    end

    it "arquivo inválido volta com o erro" do
      login
      post "/locais/#{site.id}/paineis/prontos/importar", params: { file: Rack::Test::UploadedFile.new(StringIO.new("{}"), "application/json", original_filename: "x.json") }
      expect(response).to redirect_to("/locais/#{site.id}/paineis/prontos")
      expect(flash[:alert]).to be_present
    end
  end

  describe "galeria de estilos de card (ideia 19)" do
    it "um clique aplica o estilo; a web põe os tokens e o app recebe o resolvido" do
      d = board({ "id" => "t", "type" => "tile", "bind" => luz.id })
      login
      get "/paineis/#{d.id}/editar"
      expect(response.body).to include("Estilo dos cards", "Vidro", "Minimalista")
      patch "/paineis/#{d.id}/estilo-dos-cards", params: { card_style: "vidro" }
      expect(d.reload.definition["card_style"]).to eq("vidro")
      get "/paineis/#{d.id}"
      expect(response.body).to include("--ss-card-filter: blur(16px)", "dw-card-style-vidro")
      expect(resolve(d)["card_style_now"]).to include("key" => "vidro", "glass" => true, "density" => "standard")
      patch "/paineis/#{d.id}/estilo-dos-cards", params: { card_style: "" }
      expect(d.reload.definition).not_to have_key("card_style")
      expect(Dashboards::Schema.errors(defn(card_style: "neon")).join).to include("card_style")
    end

    it "estilo é só token permitido" do
      expect(Dashboards::CardStyles.all.flat_map { _1.web.keys }.uniq - Dashboards::CardStyles::TOKENS).to be_empty
      expect(Dashboards::CardStyles.css(nil)).to eq("")
    end
  end

  it "zerar e exportar a conta levam os modelos" do
    within(tenant) { site.card_templates.create!(own_template) }
    expect(Accounts::WipeData::MODELS).to include(CardTemplate)
    expect(Accounts::WipeData.call(tenant)["card_templates"]).to eq(1)
  end
end
