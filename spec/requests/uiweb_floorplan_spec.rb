require "rails_helper"

# Planta baixa (uiweb): o widget `floorplan` é só mais um plugin do registro.
# Camadas com imagem enviada (Active Storage), pontos em % que acendem na cor
# real e alternam no toque, e cômodos que abrem a área.
RSpec.describe "Planta baixa (widget floorplan)" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:area) { within(tenant) { create(:area, site: site, name: "Teste Sala") } }
  let!(:device) { within(tenant) { create(:device, site: site, area: area, name: "Teste Abajur") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Luz", key: "teste.luz", capability: "onoff", value: true, writable: true) } }
  let!(:color) { within(tenant) { create(:point, device: device, name: "Cor", key: "teste.cor", capability: "color", value: { "mode" => "hs", "h" => 0, "s" => 100 }) } }
  let(:png) { Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") }
  let(:dashboard) { within(tenant) { Dashboard.ensure_for(site).first } }

  before do
    allow(Drivers).to receive(:supported?).and_return(true)
    post("/entrar", params: { email: user.email, password: "12345678" })
  end

  def upload(bytes, name)
    file = Tempfile.new([ "planta", File.extname(name) ]).tap { |f| f.binmode && f.write(bytes) && f.rewind }
    Rack::Test::UploadedFile.new(file.path, "image/png", true, original_filename: name)
  end

  def add_floorplan(layer)
    patch "/paineis/#{dashboard.id}/rascunho", params: { op: "add_view", title: "Teste Planta" }
    v = within(tenant) { dashboard.reload.draft["views"].last["id"] }
    patch "/paineis/#{dashboard.id}/rascunho", params: { op: "add_section", view_id: v, title: "Teste" }
    s = within(tenant) { dashboard.reload.draft["views"].last["sections"].last["id"] }
    patch "/paineis/#{dashboard.id}/rascunho", params: { op: "add_widget", target: s, view_id: v, widget: { type: "floorplan", layers: { "0" => layer } } }
    within(tenant) { dashboard.reload.draft["views"].last["sections"].last["widgets"].last }
  end

  it "vem do registro e valida camadas, pontos e cômodos" do
    expect(Dashboards::Widgets["floorplan"].label).to eq("Planta baixa")
    w = { "id" => "fp", "type" => "floorplan", "layers" => [ { "id" => "l1", "pins" => [ { "point" => "x", "x" => 120, "y" => 3 } ], "image" => "javascript:alert(1)" } ] }
    defn = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => [ w ] } ] } ] }
    expect(Dashboards::Schema.errors(defn).join).to include("imagem precisa ser um link", "x/y de 0 a 100")
    expect(Dashboards::Schema.errors(defn.deep_merge("views" => [ defn["views"][0].merge("sections" => [ { "id" => "s", "widgets" => [ w.merge("layers" => []) ] } ]) ])).join).to include("layers")
  end

  it "editor: envia a imagem, salva pontos e cômodos; a tela acende na cor real e alterna no toque" do
    w = add_floorplan("title" => "Térreo", "upload" => upload(png, "planta.png"),
                      "pins" => { "0" => { "point" => lamp.id, "x" => "25,5", "y" => "40" }, "1" => { "point" => "", "x" => "50", "y" => "50" } },
                      "rooms" => { "0" => { "area" => area.id, "x" => "0", "y" => "0", "w" => "50", "h" => "60" } })
    layer = w["layers"].first
    expect(layer).to include("title" => "Térreo", "pins" => [ { "point" => lamp.id, "x" => 25.5, "y" => 40 } ],
                             "rooms" => [ { "area" => area.id, "x" => 0, "y" => 0, "w" => 50, "h" => 60 } ])
    expect(layer["image"]).to start_with("/rails/active_storage/blobs/")
    expect(within(tenant) { dashboard.reload.files.count }).to eq(1)

    resolved = within(tenant) { Dashboards::Resolver.new(dashboard, role: "owner", definition: dashboard.draft).call }
    data = resolved["views"].last["sections"].last["widgets"].last
    expect(data["data"]["layers"].first["pins"].first).to include("point_id" => lamp.id, "color_id" => color.id)
    expect(data["data"]["layers"].first["rooms"].first).to include("name" => "Teste Sala", "on" => 1)
    expect(data["deps"]).to include(lamp.id, color.id)

    within(tenant) { dashboard.publish! }
    view = within(tenant) { dashboard.reload.definition["views"].last["id"] }
    get "/paineis/#{dashboard.id}", params: { view: view }
    expect(response.body).to include('data-controller="floorplan"', "bg-[var(--glow,var(--warn))]", "--glow: #ff0000", "Desligar Luz", "Abrir Teste Sala", layer["image"])

    get "/paineis/#{dashboard.id}/editar", params: { view: view }
    expect(response.body).to include('data-controller="floorplan-editor"', "Arraste os pontos", 'multipart/form-data')
  end

  it "recusa arquivo que não é imagem (pelo conteúdo, não pelo nome)" do
    patch "/paineis/#{dashboard.id}/rascunho", params: { op: "add_view", title: "Teste" }
    v = within(tenant) { dashboard.reload.draft["views"].last["id"] }
    patch "/paineis/#{dashboard.id}/rascunho", params: { op: "add_section", view_id: v, title: "Teste" }
    s = within(tenant) { dashboard.reload.draft["views"].last["sections"].last["id"] }
    patch "/paineis/#{dashboard.id}/rascunho", params: { op: "add_widget", target: s, view_id: v,
                                                        widget: { type: "floorplan", layers: { "0" => { "title" => "X", "upload" => upload("<script>alert(1)</script>", "planta.png") } } } }
    expect(flash[:alert]).to include("PNG, JPG ou WebP")
    expect(ActiveStorage::Blob.count).to eq(0)
  end
end
