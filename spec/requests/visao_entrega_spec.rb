require "rails_helper"

# visao-entrega: visão só para algumas telas/papéis (`visible_if` da visão) e o card de câmera com
# som e "Falar" no próprio card (`sound`/`talk`; falar gravado pela web em `/cameras/:id/falar`).
RSpec.describe "Visão por tela e câmera com som e falar" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:device) { within(tenant) { create(:device, site: site, name: "Teste Abajur") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Luz", key: "teste.luz", capability: "onoff", value: true, writable: true) } }
  let!(:cam) do
    within(tenant) do
      d = create(:device, site: site, driver: "go2rtc", name: "DVR", address: { "host" => "10.0.0.20" })
      create(:point, device: d, name: "Área Gourmet", capability: "stream", writable: true, address: { "path" => "/s19", "supports" => %w[record play_media], "talk" => true })
    end
  end
  let(:dashboard) { within(tenant) { Dashboard.ensure_for(site).first } }
  let(:media_dir) { Pathname(Dir.mktmpdir("ma-media")) }

  around do |ex|
    old = %w[MEDIA_DIR MEDIA_PUBLIC_URL].to_h { |k| [ k, ENV.fetch(k, nil) ] }
    ENV["MEDIA_DIR"] = media_dir.to_s
    ENV["MEDIA_PUBLIC_URL"] = "http://ma.local"
    ex.run
  ensure
    old.each { |k, v| ENV[k] = v }
    FileUtils.rm_rf(media_dir)
  end

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })
  def member(role) = create(:user, tenant: tenant, role: "member").tap { |u| within(tenant) { create(:site_membership, site: site, user: u, role: role) } }
  def publish(defn) = within(tenant) { dashboard.publish!(defn) }
  def defn(views, **extra) = { "schema_version" => 1, "views" => views }.merge(extra.transform_keys(&:to_s))
  def tile(id) = { "id" => id, "type" => "tile", "bind" => lamp.id }
  def camera(**props) = { "id" => "cam", "type" => "camera", "bind" => cam.id, "live" => true, "autoplay" => true }.merge(props.transform_keys(&:to_s))

  def views
    [ { "id" => "home", "title" => "Início", "sections" => [ { "id" => "s0", "widgets" => [ tile("t0") ] } ] },
      { "id" => "entrega", "title" => "Entrega", "path" => "entrega", "visible_if" => { "screen" => [ "mobile" ] },
        "sections" => [ { "id" => "s1", "widgets" => [ camera(talk: true, sound: true) ] } ] },
      { "id" => "dono", "title" => "Só do dono", "visible_if" => { "role" => [ "resident" ] }, "sections" => [ { "id" => "s2", "widgets" => [ tile("t2") ] } ] } ]
  end

  describe "visão por tela e papel" do
    it "valida o visible_if da visão (só papel, tela e aparelho) e o JSON Schema conhece a chave" do
      expect(Dashboards::Schema.errors(defn(views))).to eq([])
      bad = defn([ views.first.merge("visible_if" => { "state" => { "point" => lamp.id, "is" => true } }) ])
      expect(Dashboards::Schema.errors(bad).join).to include("visible_if da visão aceita só role, screen, device")
      expect(Dashboards::Schema.errors(defn([ views.first.merge("visible_if" => { "screen" => [ "tv" ] }) ])).join).to include("visible_if.screen")
      expect(Dashboards::Schema.errors(defn([ views.first.merge("visible_if" => {}) ])).join).to include("visible_if da visão")
      expect(Dashboards::Schema.errors(defn([ views.first.merge("visible_if" => { "role" => [ "rei" ], "device" => "x" }) ])).size).to eq(2)
      view_schema = Dashboards::JsonSchema.call.dig("$defs", "view", "properties", "visible_if")
      expect(view_schema["properties"].keys).to eq(%w[role screen device])
      expect(view_schema.dig("properties", "screen", "items", "enum")).to eq(Dashboards::Schema::SCREENS)
    end

    it "papel: a visão some do JSON de quem não está na lista (o dono vê); visão inicial escondida não vale" do
      publish(defn(views, start_view: "dono"))
      owner = within(tenant) { Dashboards::Resolver.new(dashboard.reload, role: "owner").call }
      expect(owner["views"].map { |v| v["id"] }).to eq(%w[home entrega dono])
      expect(owner["start_view"]).to eq("dono")
      guest = within(tenant) { Dashboards::Resolver.new(dashboard.reload, role: "guest").call }
      expect(guest["views"].map { |v| v["id"] }).to eq(%w[home entrega])
      expect(guest).not_to have_key("start_view")
      expect(Dashboards.pick_view(guest, nil)["id"]).to eq("home")
      expect(Dashboards.pick_view(guest, "dono")["id"]).to eq("home") # link da visão escondida abre a primeira
      expect(within(tenant) { Dashboards::Resolver.new(dashboard.reload, role: "guest").widget("t2") }).to be_nil
      lazy = within(tenant) { Dashboards::Resolver.new(dashboard.reload, role: "guest", only_view: "dono").call }
      expect(lazy["views"].reject { |v| v["lazy"] }.map { |v| v["id"] }).to eq([ "home" ])

      # Nenhuma visão para o papel: uma vazia com o nome do painel (a tela mostra o painel vazio).
      publish(defn([ views.last ]))
      only = within(tenant) { Dashboards::Resolver.new(dashboard.reload, role: "guest").call }
      expect(only["views"]).to eq([ { "id" => "dono", "title" => dashboard.name, "badges" => [], "sections" => [] } ])

      # A busca de cards também não mostra o card da visão escondida.
      publish(defn(views.map { |v| v.merge("sections" => v["sections"].map { |s| s.merge("widgets" => s["widgets"].map { |w| w.merge("label" => "Card #{w['id']}") }) }) }))
      cards = ->(u) { within(tenant) { Search::WidgetsSource.entries(Search::Context.for(u)).map { |e| e[:widget]["id"] } } }
      guest_cards = cards.call(member("guest"))
      expect(guest_cards).to include("t0")
      expect(guest_cards).not_to include("t2")
      expect(cards.call(user)).to include("t0", "t2")
    end

    it "web: a aba só do celular some nas outras telas; aberta no computador avisa e leva à primeira aba" do
      publish(defn(views))
      sign_in
      get "/paineis/#{dashboard.id}"
      expect(response.body).to match(/class="ss-chip no-underline ss-hide-tablet ss-hide-desktop"[^>]*>.*Entrega/m)
      expect(response.body).not_to include("view-fallback")
      get "/paineis/#{dashboard.id}", params: { view: "entrega" }
      body = response.body
      expect(body).to include('data-controller="view-fallback"', "Esta visão não aparece nesta tela.", "Abrir Início")
      expect(body).to include(%(data-view-fallback-url-value="/paineis/#{dashboard.id}?view=home"))
      expect(body).to include('class="mt-4 ss-hide-mobile ss-hide-desktop"', 'class="mt-4 ss-hide-mobile ss-hide-tablet"')
      expect(body).to include('data-controller="ss-filter" class="ss-hide-tablet ss-hide-desktop"')
      # No Início, o mesmo (link do Início com o local).
      get "/", params: { view: "entrega" }
      expect(response.body).to include("view-fallback", "?local=#{site.id}&amp;view=home")
    end

    it "editor: Mostrar em e Quem vê na visão; o device do JSON fica; tudo marcado tira a chave" do
      sign_in
      d = dashboard
      within(tenant) { d.save_draft!(defn(views.map { |v| v["id"] == "home" ? v.merge("visible_if" => { "device" => [ "tablet-parede" ] }) : v })) }
      get "/paineis/#{d.id}/editar", params: { view: "entrega" }
      expect(response.body).to include("view_visible[screens][]", "Mostrar em")
      expect(response.body).to match(/<input[^>]*id="vsc-mobile"[^>]*checked/)
      expect(response.body).not_to match(/<input[^>]*id="vsc-desktop"[^>]*checked/)
      patch "/paineis/#{d.id}/rascunho", params: { op: "update_view", target: "home", view_id: "home", title: "Início",
                                                  view_visible: { present: "1", screens: [ "", "mobile", "tablet" ], roles: [ "", "owner" ] } }
      home = d.reload.draft["views"].first
      expect(home["visible_if"]).to eq("device" => [ "tablet-parede" ], "screen" => %w[mobile tablet], "role" => [ "owner" ])
      patch "/paineis/#{d.id}/rascunho", params: { op: "update_view", target: "entrega", view_id: "entrega", title: "Entrega",
                                                  view_visible: { present: "1", screens: Dashboards::Schema::SCREENS } }
      expect(d.reload.draft["views"].second).not_to have_key("visible_if")
    end

    it "revisão (Lint) avisa visão inicial por tela e tela sem aba; Exportar leva a chave" do
      list = [ views.first.merge("visible_if" => { "screen" => %w[mobile tablet] }), views.second ]
      warnings = within(tenant) { Dashboards::Lint.call(site, defn(list, start_view: "entrega")) }
      kinds = warnings.map { |w| w["kind"] }
      expect(kinds).to include("view_start_screen", "view_no_screen")
      expect(warnings.find { |w| w["kind"] == "view_no_screen" }["text"]).to include("Computador")
      expect(within(tenant) { Dashboards::Lint.call(site, defn([ views.first ])) }.map { |w| w["kind"] }).not_to include("view_no_screen")

      publish(defn(views))
      manifest = within(tenant) { Dashboards::Export.dashboard(dashboard.reload) }
      preset = manifest["items"].find { |i| i["type"] == "preset" }
      expect(preset["definition"]["views"].second["visible_if"]).to eq("screen" => [ "mobile" ])
      expect(preset["definition"]["views"].third["visible_if"]).to eq("role" => [ "resident" ])
    end

    it "API: o app recebe o visible_if da visão (a lista de telas) para esconder a aba" do
      publish(defn(views))
      get "/api/v1/dashboards/#{dashboard.id}", headers: auth_headers(user)
      entrega = response.parsed_body["data"]["views"].find { |v| v["id"] == "entrega" }
      expect(entrega["visible_if"]).to eq("screen" => [ "mobile" ])
    end
  end

  describe "card de câmera: som e falar" do
    it "valida talk/sound, o formulário grava e o servidor decide o falar pelo papel e pela câmera" do
      expect(Dashboards::Schema.errors(defn([ views.first.merge("sections" => [ { "id" => "s", "widgets" => [ camera(talk: "sim", sound: 1) ] } ]) ])).join)
        .to include("talk precisa ser true ou false", "sound precisa ser true ou false")
      props = Dashboards::JsonSchema.call.dig("$defs", "widget_camera", "properties")
      expect(props).to include("talk" => { "type" => "boolean" }, "sound" => { "type" => "boolean" })
      attrs = Dashboards::Widgets::CameraWidget.attrs(ActionController::Parameters.new(bind: cam.id, autoplay: "1", talk: "1", sound: "0"))
      expect(attrs).to include("live" => true, "autoplay" => true, "talk" => true)
      expect(attrs).not_to have_key("sound")

      publish(defn(views))
      data = ->(role) { within(tenant) { Dashboards::Resolver.new(dashboard.reload, role: role).widget("cam")["data"] } }
      expect(data.call("owner")).to include("talk" => true)
      within(tenant) { cam.update!(risk: "sensitive") }
      expect(data.call("guest")).not_to have_key("talk") # convidado não comanda ponto sensível
      expect(data.call("operator")).to include("talk" => true)
      within(tenant) { cam.update!(address: cam.address.merge("supports" => %w[record])) }
      expect(data.call("owner")).not_to have_key("talk") # câmera sem alto-falante
    end

    it "web: o card traz o som, o falar gravado e os textos; sem talk, nada de microfone" do
      publish(defn(views))
      sign_in
      get "/paineis/#{dashboard.id}", params: { view: "entrega" }
      body = response.body
      expect(body).to include('data-camera-sound-value="true"', %(data-camera-talk-url-value="/cameras/#{cam.id}/falar"), 'data-action="camera#talkCard"',
                              'data-action="camera#toggleSound"', 'data-camera-target="status"', "toque no alto-falante para ouvir")
      publish(defn([ views.first.merge("sections" => [ { "id" => "s", "widgets" => [ camera ] } ]) ]))
      get "/paineis/#{dashboard.id}"
      expect(response.body).to include('data-action="camera#toggleSound"', 'data-camera-sound-value="false"')
      expect(response.body).not_to include("camera#talkCard", "camera-talk-url-value")
    end

    it "web: o falar gravado vira play_media pelo go2rtc (WAV); papel sem permissão leva 403/404" do
      sign_in
      allow(Drivers::Go2rtc).to receive(:play_audio)
      wav = Wyoming.wav("\x00\x01".b * 800, 16_000, 2, 1)
      post "/cameras/#{cam.id}/falar", params: { audio: Rack::Test::UploadedFile.new(StringIO.new(wav), "audio/wav", original_filename: "fala.wav") }
      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body["message"]).to eq("Áudio enviado para a câmera.")
      command = within(tenant) { Command.order(:created_at).last }
      expect(command).to have_attributes(command: "play_media", source: "web")
      within(tenant) { ExecuteCommandJob.perform_now(command.id) }
      expect(Drivers::Go2rtc).to have_received(:play_audio).with(anything, %r{\Ahttp://ma.local/rails/active_storage/blobs/.+\.wav\z})

      within(tenant) { cam.update!(risk: "sensitive") }
      sign_in(member("guest"))
      post "/cameras/#{cam.id}/falar", params: { audio: Rack::Test::UploadedFile.new(StringIO.new(wav), "audio/wav", original_filename: "fala.wav") }
      expect(response.status).to be_in([ 403, 404, 302 ])
      expect(within(tenant) { Command.count }).to eq(1)
    end

    it "Cameras::Talk: WAV passa direto; o que o ffmpeg não lê vai como veio; grande demais recusa" do
      wav = Wyoming.wav("\x00\x01".b * 10, 8000, 2, 1)
      expect(Cameras::Talk.wav(wav, "audio/mp4")).to eq([ wav, "audio/wav" ]) # o app antigo rotulava o WAV como m4a
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
      expect(Cameras::Talk.wav("webm!", "audio/webm;codecs=opus")).to eq([ "webm!", "audio/webm;codecs=opus" ])
      expect(Cameras::Talk.wav("x", "")).to eq([ "x", "audio/mp4" ])
      expect { Cameras::Talk.call(cam, "x" * (Cameras::Talk::MAX + 1), "audio/wav", source: "web") }.to raise_error(Cameras::Talk::TooBig)
      sign_in
      big = Rack::Test::UploadedFile.new(StringIO.new("x" * (Cameras::Talk::MAX + 1)), "audio/webm", original_filename: "fala.webm")
      post "/cameras/#{cam.id}/falar", params: { audio: big }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
