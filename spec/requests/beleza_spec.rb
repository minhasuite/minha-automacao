require "rails_helper"

# Beleza dos painéis (proposta de personalização: ideias 15 a 18 e 21, P2.4 e P2.5):
# noite pelo sol ou por horário, fundo por hora do dia e escurecer à noite, tile com
# o brilho real, planta como visão principal e visão inicial, acenos de estado,
# quiosque com relógio grande e álbum, e o card de terceiros "só web".
RSpec.describe "Beleza dos painéis" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:area) { within(tenant) { create(:area, site: site, name: "Teste Sala") } }
  let!(:device) { within(tenant) { create(:device, site: site, area: area, name: "Teste Abajur") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Luz", key: "teste.luz", capability: "onoff", value: true, writable: true) } }
  let!(:dim) { within(tenant) { create(:point, device: device, name: "Brilho", key: "teste.brilho", capability: "dimmer", value: 25, writable: true) } }
  let!(:color) { within(tenant) { create(:point, device: device, name: "Cor", key: "teste.cor", capability: "color", value: { "mode" => "hs", "h" => 0, "s" => 100 }) } }
  let!(:door) { within(tenant) { create(:point, device: create(:device, site: site, area: area, name: "Teste Porta"), name: "Porta", key: "teste.porta", capability: "contact", value: true) } }
  let(:png) { Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") }
  let(:dashboard) { within(tenant) { Dashboard.ensure_for(site).first } }
  let(:zone) { ActiveSupport::TimeZone[site.timezone] }

  before do
    allow(Drivers).to receive(:supported?).and_return(true)
    post("/entrar", params: { email: user.email, password: "12345678" })
  end

  def upload(bytes, name)
    file = Tempfile.new([ "foto", File.extname(name) ]).tap { |f| f.binmode && f.write(bytes) && f.rewind }
    Rack::Test::UploadedFile.new(file.path, "image/png", true, original_filename: name)
  end

  def publish(defn) = within(tenant) { dashboard.publish!(defn) }

  def defn(views, **extra) = { "schema_version" => 1, "views" => views }.merge(extra.transform_keys(&:to_s))

  describe "tema: noite pelo sol ou por horário e fundo por hora (P2.4 e ideia 15)" do
    it "noite pelo sol com coordenadas, pela janela sem elas ou quando pedida" do
      t = { "key" => "lista", "night" => "grafite" }
      # Sem latitude/longitude: a janela padrão 18:00–06:00.
      expect(Dashboards::Themes.night?(t, site, zone.parse("2026-11-02 17:59"))).to be(false)
      expect(Dashboards::Themes.night?(t, site, zone.parse("2026-11-02 18:00"))).to be(true)
      expect(Dashboards::Themes.night?(t, site, zone.parse("2026-11-03 05:59"))).to be(true)
      # Janela própria que não cruza a meia-noite.
      expect(Dashboards::Themes.night?(t.merge("night_by" => "window", "night_from" => "01:00", "night_to" => "04:30"), site, zone.parse("2026-11-02 03:00"))).to be(true)
      expect(Dashboards::Themes.night?(t.merge("night_by" => "window", "night_from" => "01:00", "night_to" => "04:30"), site, zone.parse("2026-11-02 05:00"))).to be(false)

      within(tenant) { site.update!(latitude: -3.73, longitude: -38.52) } # Fortaleza: sol ~5h20 e ~17h40
      expect(Dashboards::Themes.night?(t, site, zone.parse("2026-11-02 17:55"))).to be(true)
      expect(Dashboards::Themes.night?(t, site, zone.parse("2026-11-02 05:45"))).to be(false)
      expect(Dashboards::Themes.night?(t.merge("night_by" => "window"), site, zone.parse("2026-11-02 17:55"))).to be(false)
      # Sol que não nasce (círculo polar): cai na janela.
      allow(Sun).to receive(:at).and_return(nil)
      expect(Dashboards::Themes.night?(t, site, zone.parse("2026-11-02 19:00"))).to be(true)
    end

    it "fundo da faixa do dia (horário e sol), escurece à noite; web e API" do
      within(tenant) { site.update!(latitude: -3.73, longitude: -38.52) }
      theme = { "key" => "aurora", "dim" => 40, "image" => "/rails/fundo.png",
                "backgrounds" => [ { "from" => "sunrise", "color" => "#fde68a", "color2" => "#38bdf8" }, { "from" => "12:00", "image" => "/rails/meio-dia.png" },
                                   { "from" => "sunset", "color" => "#1e1b4b" } ] }
      morning = zone.parse("2026-11-02 08:00")
      noon = zone.parse("2026-11-02 13:00")
      late = zone.parse("2026-11-02 23:00")
      before_sun = zone.parse("2026-11-02 03:00")
      expect(Dashboards::Themes.background_now(theme, site, morning)).to eq("color" => "#fde68a", "color2" => "#38bdf8")
      expect(Dashboards::Themes.background_now(theme, site, noon)).to eq("image" => "/rails/meio-dia.png")
      expect(Dashboards::Themes.background_now(theme, site, late)).to eq("color" => "#1e1b4b")
      expect(Dashboards::Themes.background_now(theme, site, before_sun)).to eq("color" => "#1e1b4b") # antes da 1ª: a última de ontem
      expect(Dashboards::Themes.background_now({}, site, noon)).to be_nil

      r = Dashboards::Themes.resolve({ "theme" => theme }, {}, site, now: morning)
      expect(r).to include("is_night" => false, "wall" => { "color" => "#fde68a", "color2" => "#38bdf8" })
      expect(r).not_to have_key("image") # a faixa de cor tira a foto do tema
      expect(r).not_to have_key("dim")
      expect(Dashboards::Themes.resolve({ "theme" => theme }, {}, site, now: noon)).to include("image" => "/rails/meio-dia.png")
      expect(Dashboards::Themes.resolve({ "theme" => theme }, {}, site, now: late)).to include("is_night" => true, "dim" => 40)
      expect(Dashboards::Themes.wall_css("color" => "#000000", "color2" => "#ffffff")).to eq("linear-gradient(160deg, #000000, #ffffff)")

      publish(within(tenant) { dashboard.published.deep_dup }.merge("theme" => theme))
      travel_to(late) { get "/paineis/#{dashboard.id}" }
      expect(response.body).to include("ss-wall", "is-dim", "is-night", "--ss-wall: #1e1b4b", "--ss-wall-dim: 40%")
      travel_to(morning) { get "/api/v1/dashboards/#{dashboard.id}", headers: auth_headers(user) }
      expect(data["views"].first["theme_now"]).to include("is_night" => false, "wall" => { "color" => "#fde68a", "color2" => "#38bdf8" })
    end

    it "esquema valida as chaves novas" do
      bad = { "key" => "lista", "night_by" => "lua", "night_from" => "25:00", "dim" => 99,
              "backgrounds" => [ { "from" => "meio-dia", "color" => "red" }, { "from" => "10:00" } ] }
      errors = Dashboards::Themes.errors(bad, "painel").join(" | ")
      expect(errors).to include("night_by", "night_from", "dim", "from (HH:MM", "#rrggbb", "image ou color")
      expect(Dashboards::Themes.errors({ "backgrounds" => Array.new(7) { { "from" => "10:00", "color" => "#000000" } } }, "p").join).to include("até 6")
      expect(Dashboards::Themes.errors({ "key" => "lista", "night_by" => "sun", "dim" => 30, "backgrounds" => [ { "from" => "sunset", "color" => "#000000" } ] }, "p")).to eq([])
    end

    it "editor: formulário de noite e de fundo por hora vira JSON (foto enviada, cor e degradê)" do
      get "/paineis/#{dashboard.id}/editar"
      expect(response.body).to include("Quando é noite", "Fundo por hora do dia", 'name="theme[backgrounds][0][kind]"', 'name="theme[dim]"')

      patch "/paineis/#{dashboard.id}/rascunho", params: { op: "theme", view_id: "home", theme: {
        key: "lista", night_by: "window", night_from: "19:30", night_to: "06:00", dim: "35",
        backgrounds: { "0" => { kind: "time", time: "07:00", style: "gradient", color: "#FDE68A", color2: "#38bdf8" },
                       "1" => { kind: "sunset", style: "image", upload: upload(png, "noite.png") },
                       "2" => { kind: "time", time: "", style: "color", color: "#000000" },
                       "3" => { kind: "time", time: "12:00", style: "color", color: "#ffffff", remove: "1" } } } }
      theme = within(tenant) { dashboard.reload.draft["theme"] }
      expect(theme).to include("key" => "lista", "night_by" => "window", "night_from" => "19:30", "dim" => 35)
      expect(theme).not_to have_key("night_to") # o padrão não vai no JSON
      expect(theme["backgrounds"].first).to eq("from" => "07:00", "color" => "#fde68a", "color2" => "#38bdf8")
      expect(theme["backgrounds"].last).to include("from" => "sunset")
      expect(theme["backgrounds"].last["image"]).to start_with("/rails/active_storage/")
      expect(theme["backgrounds"].size).to eq(2)
      expect(Dashboards::Schema.errors(within(tenant) { dashboard.reload.draft })).to eq([])
    end
  end

  describe "tile com o brilho real (ideia 16) e acenos (ideia 18)" do
    it "luz com dimmer irmão manda level_id; a tela acende na cor e no brilho e acena" do
      tile = { "id" => "w-luz", "type" => "tile", "bind" => lamp.id }
      people = { "id" => "w-gente", "type" => "people" }
      publish(defn([ { "id" => "home", "title" => "Início", "sections" => [ { "id" => "s", "widgets" => [ tile, people ] } ] } ]))
      resolved = within(tenant) { Dashboards::Resolver.new(dashboard.reload, role: "owner").call }
      w = resolved["views"].first["sections"].first["widgets"].first
      expect(w["data"]).to include("color_id" => color.id, "level_id" => dim.id)
      expect(w["deps"]).to include(dim.id, color.id)

      get "/paineis/#{dashboard.id}"
      expect(response.body).to include("has-level", "--ss-level: 0.25", 'data-ss-cue-kind-value="on"', 'data-ss-cue-key-value="tile-w-luz"')
      expect(response.body).to include("ss-cue")

      within(tenant) { lamp.update!(capability: "dimmer", value: 80) } # o próprio dimmer é o brilho
      resolved = within(tenant) { Dashboards::Resolver.new(dashboard.reload, role: "owner").call }
      expect(resolved["views"].first["sections"].first["widgets"].first["data"]["level_id"]).to eq(lamp.id)
    end

    it "dw_level: só luz com brilho, proporcional à faixa" do
      helper = Class.new { include DashboardsHelper }.new
      p = { "capability" => "dimmer", "name" => "Luz", "device" => "Abajur", "value" => 50 }
      w = { "data" => { "level_id" => "b" } }
      expect(helper.dw_level(w, { "b" => { "value" => 128, "min" => 0, "max" => 255 } }, p)).to eq(0.5)
      expect(helper.dw_level(w, { "b" => { "value" => nil } }, p)).to be_nil
      expect(helper.dw_level({ "data" => {} }, {}, p)).to be_nil
      expect(helper.dw_level(w, { "b" => { "value" => 5 } }, p.merge("name" => "Ventilador", "device" => "Teto"))).to be_nil
    end
  end

  describe "planta como visão principal e visão inicial (ideia 17)" do
    let(:plan) do
      { "id" => "fp", "type" => "floorplan", "layers" => [ { "id" => "l1", "title" => "Térreo",
                                                             "pins" => [ { "point" => lamp.id, "x" => 20, "y" => 20 }, { "point" => door.id, "x" => 80, "y" => 50 } ],
                                                             "rooms" => [ { "area" => area.id, "x" => 0, "y" => 0, "w" => 50, "h" => 50 } ] } ] }
    end

    it "tipo de visão planta: a planta no topo, o resto embaixo; cômodo na cor da lâmpada; porta abre" do
      views = [ { "id" => "home", "title" => "Início", "sections" => [ { "id" => "s0", "widgets" => [ { "id" => "t0", "type" => "tile", "bind" => lamp.id } ] } ] },
                { "id" => "casa", "title" => "Casa", "type" => "plan", "sections" => [ { "id" => "s1", "widgets" => [ { "id" => "t1", "type" => "tile", "bind" => door.id }, plan ] } ] } ]
      publish(defn(views, start_view: "casa"))
      expect(Dashboards::Schema.errors(defn(views, start_view: "casa"))).to eq([])
      expect(Dashboards::Schema.errors(defn(views, start_view: "nao-existe")).join).to include("start_view")

      resolved = within(tenant) { Dashboards::Resolver.new(dashboard.reload, role: "owner").call }
      expect(resolved["start_view"]).to eq("casa")
      room = resolved["views"].last["sections"].first["widgets"].last["data"]["layers"].first["rooms"].first
      expect(room).to include("on" => 2, "glow_id" => color.id) # liga/desliga e o brilho acesos

      get "/paineis/#{dashboard.id}" # sem ?view=, abre na visão inicial
      body = response.body
      expect(body).to include("dw-fp-full", "dw-fp-door", 'data-ss-cue-kind-value="open"', "--glow: #ff0000")
      expect(body.index("dw-fp-full")).to be < body.index(%(data-points="#{door.id}")) if body.include?(%(data-points="#{door.id}"))
      get "/paineis/#{dashboard.id}", params: { view: "home" }
      expect(response.body).not_to include("dw-fp-full")

      get "/api/v1/dashboards/#{dashboard.id}", headers: auth_headers(user)
      expect(data["start_view"]).to eq("casa")
    end

    it "sem planta, a visão avisa; o editor marca e desmarca a visão inicial; tirar a visão limpa" do
      publish(defn([ { "id" => "home", "title" => "Início", "sections" => [] }, { "id" => "p", "title" => "Planta", "type" => "plan", "sections" => [ { "id" => "sp", "widgets" => [ { "id" => "tp", "type" => "tile", "bind" => lamp.id } ] } ] } ]))
      get "/paineis/#{dashboard.id}", params: { view: "p" }
      expect(response.body).to include("ainda não tem uma planta")

      get "/paineis/#{dashboard.id}/editar", params: { view: "p" }
      expect(response.body).to include("Abrir o painel nesta visão", "Planta da casa")
      patch "/paineis/#{dashboard.id}/rascunho", params: { op: "update_view", target: "p", view_id: "p", title: "Planta", view_type: "plan", start_view: "1" }
      expect(within(tenant) { dashboard.reload.draft["start_view"] }).to eq("p")
      patch "/paineis/#{dashboard.id}/rascunho", params: { op: "update_view", target: "home", view_id: "home", title: "Início", start_view: "0" }
      expect(within(tenant) { dashboard.reload.draft["start_view"] }).to eq("p") # desmarcar outra não mexe
      patch "/paineis/#{dashboard.id}/rascunho", params: { op: "remove", kind: "view", target: "p", view_id: "home" }
      expect(within(tenant) { dashboard.reload.draft }).not_to have_key("start_view")
    end
  end

  describe "card de terceiros só na web (P2.5)" do
    it "o registro marca, o data leva web_only e o editor avisa" do
      expect(Dashboards::Widgets["custom_card"].web_only?).to be(true)
      expect(Dashboards::Widgets["tile"].web_only?).to be(false)
      within(tenant) do
        r = Dashboards::Resolver.new(dashboard, role: "owner")
        expect(Dashboards::Widgets["custom_card"].data(r, { "card" => "nao/existe" }, []).first).to eq("missing" => true, "web_only" => true)
      end
      get "/paineis/#{dashboard.id}/editar"
      expect(response.body).to include("Este card roda só na web")
    end
  end

  describe "quiosque (ideia 21)" do
    it "relógio grande, movimento e álbum de fotos (web e API)" do
      get "/paineis/#{dashboard.id}", params: { quiosque: 1 }
      expect(response.body).not_to include(%(data-kiosk-target="bigClock"))
      expect(response.body).to include("Álbum do protetor de tela", "Nenhuma foto no álbum.")
      patch "/quiosque", params: { saver: "photos", idle: "3", clock: "1", dim: "1" }
      get "/paineis/#{dashboard.id}"
      expect(response.body).to include('data-kiosk-target="bigClock"', 'data-kiosk-slides-value="[]"')

      within(tenant) { dashboard.files.attach(io: StringIO.new(png), filename: "planta.png", content_type: "image/png") } # imagem do painel (não é do álbum)
      get "/paineis/#{dashboard.id}"
      expect(response.body).to include("planta.png") # sem álbum, passam as imagens do painel

      post "/paineis/#{dashboard.id}/album", params: { photos: [ upload(png, "praia.png"), upload(png, "serra.png") ] }
      expect(flash[:notice]).to eq("2 fotos entraram no álbum.")
      album = within(tenant) { dashboard.reload.album }
      expect(album.map { |f| f.filename.to_s }).to contain_exactly("praia.png", "serra.png")
      get "/paineis/#{dashboard.id}"
      expect(response.body).to include("praia.png", "2 fotos no álbum.")
      expect(response.body[/data-kiosk-slides-value="[^"]*"/]).not_to include("planta.png")

      get "/api/v1/dashboards/#{dashboard.id}/album", headers: auth_headers(user)
      expect(data.map { |x| x["url"] }).to all(start_with("/rails/active_storage/blobs/"))
      expect(data.size).to eq(2)

      post "/paineis/#{dashboard.id}/album", params: { photos: [ Rack::Test::UploadedFile.new(StringIO.new("<svg/>"), "image/png", original_filename: "x.png") ] }
      expect(flash[:alert]).to include("PNG, JPG ou WebP")

      delete "/paineis/#{dashboard.id}/album/#{album.first.id}"
      expect(within(tenant) { dashboard.reload.album.size }).to eq(1)
    end

    it "quem só vê não mexe no álbum" do
      viewer = create(:user, tenant: tenant, role: "member")
      within(tenant) { create(:site_membership, site: site, user: viewer, role: "viewer") }
      post("/entrar", params: { email: viewer.email, password: "12345678" })
      get "/paineis/#{dashboard.id}", params: { quiosque: 1 }
      expect(response.body).not_to include("Álbum do protetor de tela")
      post "/paineis/#{dashboard.id}/album", params: { photos: [ upload(png, "x.png") ] }
      expect(within(tenant) { dashboard.reload.album }).to be_empty
    end
  end
end
