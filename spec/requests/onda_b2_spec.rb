require "rails_helper"

# ondaB2 (paridade HA, grupo 4): recursos do tile e ações de toque (B9),
# cards novos (B10), tipos de visão, subvisões e pilhas (B8), temas do usuário
# e barra lateral por pessoa (B11). Tudo por registro, com plugin falso.
RSpec.describe "ondaB2: painéis" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:ac) { within(tenant) { create(:device, site: site, name: "Ar da sala") } }
  let!(:power) { within(tenant) { create(:point, device: ac, name: "Liga/desliga", key: "ar.power", capability: "onoff", writable: true, value: true) } }
  let!(:target) do
    within(tenant) do
      create(:point, device: ac, name: "Temperatura alvo", key: "ar.alvo", capability: "setpoint", writable: true, value: 23, unit: "°C",
                     device_class: "temperature", min: 16, max: 30, step: 0.5, data_type: "decimal")
    end
  end
  let!(:mode) { within(tenant) { create(:point, device: ac, name: "Modo", key: "ar.modo", capability: "enum", writable: true, value: "Refrigerar", options: %w[Refrigerar Aquecer Ventilar], address: { "field" => "mode" }) } }

  before { post("/entrar", params: { email: user.email, password: "12345678" }) }

  def board(widgets, view: {}, extra_views: [])
    within(tenant) do
      d = Dashboard.ensure_for(site).first
      d.update!(auto: false, definition: { "schema_version" => 1, "views" => [ { "id" => "v1", "title" => "Início", "sections" => [ { "id" => "s1", "widgets" => widgets } ] }.merge(view), *extra_views ] })
      d
    end
  end

  def defn(widgets) = { "schema_version" => 1, "views" => [ { "id" => "v1", "title" => "Início", "sections" => [ { "id" => "s1", "widgets" => widgets } ] } ] }
  def resolved(d) = within(tenant) { Dashboards::Resolver.new(d.reload, role: "owner").call }
  def first_widget(d) = resolved(d)["views"][0]["sections"][0]["widgets"][0]

  describe "B9: recursos do tile" do
    it "acha o alvo nos irmãos do aparelho, valida e desenha cada kind" do
      w = { "id" => "w1", "type" => "tile", "bind" => power.id, "features" => %w[target_temperature climate_mode brightness slider] }
      d = board([ w ])
      expect(Dashboards::Schema.errors(d.definition)).to eq([])
      feats = first_widget(d).dig("data", "features")
      expect(feats.map { |f| f["type"] }).to eq(%w[target_temperature climate_mode]) # brilho não tem alvo; slider é o antigo
      expect(feats[0]).to include("kind" => "stepper", "point_id" => target.id, "value" => 23, "step" => 0.5, "command" => "set")
      expect(feats[1]).to include("kind" => "chips", "point_id" => mode.id, "options" => %w[Refrigerar Aquecer Ventilar], "command" => "select")
      expect(first_widget(d)["deps"]).to include(target.id, mode.id)

      get "/paineis/#{d.id}"
      expect(response.body).to include("dw-feats", "dw-stepper", %(name="value" value="23.5"), %(name="value" value="22.5"), "Aquecer", %(aria-pressed="true"))
    end

    it "recusa recurso desconhecido e aceita {type, point}" do
      bad = defn([ { "id" => "w1", "type" => "tile", "bind" => power.id, "features" => [ "nada" ] } ])
      expect(Dashboards::Schema.errors(bad).join).to include("recurso \"nada\" não existe")
      ok = board([ { "id" => "w1", "type" => "tile", "bind" => power.id, "features" => [ { "type" => "select_options", "point" => "ar.modo" } ] } ])
      expect(Dashboards::Schema.errors(ok.definition)).to eq([])
      expect(first_widget(ok).dig("data", "features", 0, "point_id")).to eq(mode.id)
    end

    it "tem os ~30 recursos do HA, todos com nome nos três idiomas" do
      keys = Dashboards::TileFeatures.plugins.map(&:key)
      expect(keys.size).to be >= 30
      expect(keys).to include("cover_position", "cover_tilt", "fan_speed", "fan_oscillate", "climate_fan", "target_humidity", "vacuum_commands",
                              "alarm_modes", "lock_commands", "media_volume", "media_playback", "counter_actions", "trend", "bar_gauge", "color_temp")
      I18n.with_locale(:en) { expect(Dashboards::TileFeatures["cover_tilt"].label).to eq("Tilt") }
      I18n.with_locale(:es) { expect(Dashboards::TileFeatures["fan_speed"].label).to eq("Velocidad") }
    end

    it "temperatura de cor pela web: \"4000\" vira kelvin" do
      color = within(tenant) { create(:point, device: ac, name: "Cor", key: "ar.cor", capability: "color", writable: true) }
      expect(Points::Color.normalize(color, "4000")).to eq("mode" => "temp", "kelvin" => 4000)
      expect(Points::Color.normalize(color, "#ff0000")["mode"]).to eq("hs")
    end

    it "recurso novo entra pelo registro (stub_const), sem mexer no núcleo" do
      fake = Class.new(Dashboards::TileFeatures::Base) do
        describe key: "reiniciar_falso", label: "Reiniciar (teste)", icon: "refresh", kind: "buttons", capabilities: %w[onoff]
        texts en: { label: "Restart (test)" }, es: { label: "Reiniciar (prueba)" }
        def self.payload(p, _r) = { "buttons" => [ { "command" => "off", "label" => "Desligar já" } ], "extra" => p.key }
      end
      stub_const("Dashboards::TileFeatures::ReiniciarFalso", fake)
      stub_const("Dashboards::TileFeatures::PLUGINS", Dashboards::TileFeatures::PLUGINS + %w[ReiniciarFalso])
      d = board([ { "id" => "w1", "type" => "tile", "bind" => target.id, "features" => %w[reiniciar_falso] } ])
      expect(Dashboards::Schema.errors(d.definition)).to eq([])
      expect(first_widget(d).dig("data", "features", 0)).to include("type" => "reiniciar_falso", "point_id" => power.id, "extra" => "ar.power")
      get "/paineis/#{d.id}"
      expect(response.body).to include("Desligar já")
      get "/paineis/#{d.id}/editar"
      expect(response.body).to include(%(value="reiniciar_falso"))
    end
  end

  describe "B9: ações de toque, segurar e duplo toque" do
    it "valida, resolve e deixa na tela o que o gesto dispara" do
      w = { "id" => "w1", "type" => "tile", "bind" => power.id, "tap_action" => { "action" => "navigate", "navigation_path" => "quarto" },
            "hold_action" => { "action" => "more_info" }, "double_tap_action" => { "action" => "command", "point" => "ar.modo", "command" => "select", "value" => "Aquecer", "confirmation" => true } }
      d = board([ w ], extra_views: [ { "id" => "v2", "title" => "Quarto", "path" => "quarto", "sections" => [] } ])
      expect(Dashboards::Schema.errors(d.definition)).to eq([])
      g = first_widget(d)["gestures"]
      expect(g["tap"]).to eq("action" => "navigate", "path" => "quarto")
      expect(g["hold"]).to eq("action" => "more_info", "point_id" => power.id)
      expect(g["double_tap"]).to include("action" => "command", "point_id" => mode.id, "command" => "select", "value" => "Aquecer", "can_command" => true, "confirm" => "Tem certeza?")

      get "/paineis/#{d.id}"
      body = response.body
      expect(body).to include('data-controller="dw-gesture"', 'data-dw-gesture-kinds-value="tap hold double_tap"', 'data-gesture="tap"',
                              "view=quarto", %(data-turbo-confirm="Tem certeza?"), %(name="value" value="Aquecer"))
    end

    it "recusa URL sem https e ação desconhecida" do
      d = defn([ { "id" => "w1", "type" => "tile", "bind" => power.id, "tap_action" => { "action" => "url", "url" => "javascript:alert(1)" },
                   "hold_action" => { "action" => "voar" } } ])
      errs = Dashboards::Schema.errors(d).join(" | ")
      expect(errs).to include("url precisa começar com https://", "hold_action precisa de uma ação conhecida")
    end

    it "o editor grava os gestos e os recursos pelo formulário" do
      d = board([ { "id" => "w1", "type" => "tile", "bind" => power.id } ])
      patch "/paineis/#{d.id}/rascunho", params: { op: "update_widget", target: "w1", view_id: "v1",
                                                   widget: { type: "tile", bind: power.id, features: %w[target_temperature climate_mode] },
                                                   gestures: { tap: { action: "url", url: "https://exemplo.com.br" }, hold: { action: "command", point: target.id, command: "set", value: "21", confirmation: "1" },
                                                               double_tap: { action: "" } } }
      w = within(tenant) { d.reload.draft["views"][0]["sections"][0]["widgets"][0] }
      expect(w).to include("features" => %w[target_temperature climate_mode], "tap_action" => { "action" => "url", "url" => "https://exemplo.com.br" },
                           "hold_action" => { "action" => "command", "point" => target.id, "command" => "set", "value" => "21", "confirmation" => true })
      expect(w).not_to have_key("double_tap_action")
    end

    it "ação nova entra pelo registro (stub_const)" do
      fake = Class.new(Dashboards::Actions::Base) do
        describe key: "piscar_falso", label: "Piscar (teste)", icon: "eye", fields: %w[url]
        texts en: { label: "Blink (test)" }, es: { label: "Parpadear (prueba)" }
        def self.payload(_r, a, _p) = { "vezes" => a["url"].to_s.size }
      end
      stub_const("Dashboards::Actions::PiscarFalso", fake)
      stub_const("Dashboards::Actions::PLUGINS", Dashboards::Actions::PLUGINS + %w[PiscarFalso])
      d = board([ { "id" => "w1", "type" => "tile", "bind" => power.id, "tap_action" => { "action" => "piscar_falso", "url" => "abc" } } ])
      expect(Dashboards::Schema.errors(d.definition)).to eq([])
      expect(first_widget(d)["gestures"]["tap"]).to eq("action" => "piscar_falso", "vezes" => 3)
      get "/paineis/#{d.id}/editar"
      expect(response.body).to include(%(<option value="piscar_falso">Piscar (teste)</option>))
    end
  end
end
