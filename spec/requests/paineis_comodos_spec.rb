require "rails_helper"

# Visões de cômodo arrumadas (Dashboards::RoomLayout) e a barra de cenas que
# não passa da largura da coluna.
RSpec.describe "Painéis: visões de cômodo" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:area) { within(tenant) { create(:area, site: site, name: "Cozinha") } }
  let!(:device) { within(tenant) { create(:device, site: site, area: area, name: "Cozinha") } }
  let!(:luz) { within(tenant) { create(:point, device: device, name: "Luz", writable: true, value: false) } }
  let!(:charme) { within(tenant) { create(:point, device: device, name: "Charme", writable: true, value: false) } }
  let!(:porta) { within(tenant) { create(:point, device: device, name: "Abertura", capability: "contact", device_class: "door", writable: false, value: false) } }
  let!(:movimento) { within(tenant) { create(:point, device: device, name: "Movimento", capability: "motion", writable: false, value: false) } }
  let!(:echo) { within(tenant) { create(:point, device: device, name: "Falar", capability: "speaker", writable: true) } }
  let!(:temp) { within(tenant) { create(:point, device: device, name: "Temperatura", capability: "measure", unit: "°C", writable: false, value: 24) } }
  let!(:auto) do
    within(tenant) { create(:point, device: device, name: "Push ao abrir", writable: true, value: true, address: { "automation_id" => SecureRandom.uuid }) }
  end
  let!(:cena) { within(tenant) { site.scenes.create!(name: "Jantar romântico com luz baixa e música ambiente", items: [ { "point_id" => luz.id, "command" => "on" } ]) } }
  let(:room) do
    { "id" => "v-cozinha", "title" => "Cozinha", "area" => area.id, "subview" => true,
      "badges" => [ { "id" => "b-1", "type" => "stat", "bind" => movimento.id, "label" => "Movimento", "aggregate" => "last" } ],
      "sections" => [
        { "id" => "s-1", "span" => { "mobile" => 12, "tablet" => 6, "desktop" => 4 }, "widgets" => [
          heading("h-1", "Iluminação"), tile("t-luz", luz), heading("h-2", "Portas"), tile("t-porta", porta, "visible_if" => { "state" => { "point" => porta.id, "is" => "on" } })
        ] },
        { "id" => "s-2", "span" => { "mobile" => 12, "tablet" => 6, "desktop" => 4 }, "widgets" => [
          heading("h-3", "Cenas"), { "id" => "sb-1", "type" => "scene_bar", "scenes" => [ cena.id ], "span" => { "mobile" => 6, "tablet" => 6, "desktop" => 6 } },
          tile("t-charme", charme, "tap_action" => { "action" => "toggle", "confirmation" => "Ligar?" })
        ] },
        { "id" => "s-3", "span" => { "mobile" => 12, "tablet" => 6, "desktop" => 4 }, "widgets" => [
          heading("h-4", "Mídia"), tile("t-echo", echo), { "id" => "cam", "type" => "camera", "bind" => echo.id },
          tile("t-mov", movimento), tile("t-temp", temp), tile("t-auto", auto),
          { "id" => "ch", "type" => "chart", "binds" => [ temp.id ], "range" => "24h" }
        ] }
      ] }
  end
  let(:defn) { { "schema_version" => 1, "views" => [ { "id" => "v-home", "title" => "Home", "sections" => [ { "id" => "s-h", "widgets" => [ tile("t-h", luz) ] } ] }, room ] } }

  def tile(id, point, **extra) = { "id" => id, "type" => "tile", "bind" => point.id, "name" => point.name, "span" => { "mobile" => 6, "tablet" => 6, "desktop" => 6 } }.merge(extra.stringify_keys)
  def heading(id, title) = { "id" => id, "type" => "heading", "title" => title }


  it "classifica por tipo e ponto: selos no topo, ações, cenas e automações, mídia" do
    after, report = within(tenant) { Dashboards::RoomLayout.view(room, site) }
    expect(after["badges"].map { _1["id"] }).to eq(%w[b-1 t-porta])
    expect(after["badges"].last).to include("type" => "stat", "bind" => porta.id, "label" => "Abertura", "icon" => "mdi:door", "aggregate" => "last",
                                            "visible_if" => { "state" => { "point" => porta.id, "is" => "on" } })
    expect(report[:badge_dup]).to eq([ "Movimento" ])
    secs = after["sections"]
    expect(secs.map { _1["id"] }).to eq(%w[s-1 s-2 s-3])
    expect(secs.map { |s| s["widgets"].map { _1["id"] } }).to eq([ %w[h-1 t-luz t-charme], %w[h-3 sb-1 t-auto], %w[h-4 t-echo cam t-temp ch] ])
    expect(secs.map { _1["span"] }).to all(include("mobile" => 12, "desktop" => 4))
    expect(secs.map { _1.dig("span", "tablet") }).to eq([ 6, 6, 12 ])
    # Configuração do widget mantida; a barra de cena ocupa a coluna fora do celular.
    expect(secs[0]["widgets"].last).to eq(room["sections"][1]["widgets"].last)
    expect(secs[1]["widgets"][1]["span"]).to eq("mobile" => 6, "tablet" => 12, "desktop" => 12)

    again, = within(tenant) { Dashboards::RoomLayout.view(after, site) }
    expect(again).to eq(after)
  end

  it "coluna vazia sai e a largura se divide; visão que não é de seções fica igual" do
    media = room["sections"][2].merge("widgets" => room["sections"][2]["widgets"].reject { _1["id"] == "t-auto" })
    two = room.merge("sections" => [ room["sections"][0], { "id" => "s-2", "widgets" => [] }, media ])
    after, = within(tenant) { Dashboards::RoomLayout.view(two, site) }
    expect(after["sections"].map { _1["id"] }).to eq(%w[s-1 s-2])
    expect(after["sections"].map { _1["span"] }).to all(eq("mobile" => 12, "tablet" => 6, "desktop" => 6))
    only = room.merge("sections" => [ room["sections"][0] ])
    after, = within(tenant) { Dashboards::RoomLayout.view(only, site) }
    expect(after["sections"].map { _1["span"] }).to eq([ { "mobile" => 12, "tablet" => 12, "desktop" => 6 } ])
    panel = room.merge("type" => "panel")
    expect(within(tenant) { Dashboards::RoomLayout.view(panel, site) }.first).to eq(panel)
  end

  it "apply! sem publicar só mostra; publicando grava versão nova e válida (só visões com área)" do
    dashboard = within(tenant) { site.dashboards.create!(name: "Casa", kind: "custom", definition: defn).tap { _1.publish!(defn, author: user) } }
    io = StringIO.new
    within(tenant) { Dashboards::RoomLayout.apply!(dashboard, io: io) }
    expect(io.string).to include("== v-cozinha", "antes  s-1(4)", "depois selos: Movimento, Abertura")
    expect(io.string).not_to include("v-home")
    expect(dashboard.reload.version).to eq(1)

    within(tenant) { Dashboards::RoomLayout.apply!(dashboard, publish: true, author: user, io: io) }
    dashboard.reload
    expect(dashboard.version).to eq(2)
    expect(dashboard.definition["views"][0]).to eq(defn["views"][0])
    expect(dashboard.definition["views"][1]["badges"].size).to eq(2)
    expect(within(tenant) { Dashboards::RoomLayout.apply!(dashboard, publish: true, io: io) }).to eq(dashboard.definition)
    expect(dashboard.reload.version).to eq(2) # nada mudou: não publica de novo
  end

  it "a barra de cenas não passa da coluna: chip limitado e nome com reticências" do
    dashboard = within(tenant) { site.dashboards.create!(name: "Casa", kind: "custom", definition: defn).tap { _1.publish!(defn, author: user) } }
    post "/entrar", params: { email: user.email, password: "12345678" }
    get "/paineis/#{dashboard.id}", params: { view: "v-cozinha" }
    expect(response).to have_http_status(:ok)
    html = Nokogiri::HTML(response.body)
    chip = html.at_css("form.contents button.ss-chip, .ss-chips[role=group] .ss-chip")
    expect(chip["class"]).to include("max-w-full")
    expect(chip.at_css("span.truncate.min-w-0").text).to eq(cena.name)
    expect(chip["title"]).to eq(cena.name)
  end
end
