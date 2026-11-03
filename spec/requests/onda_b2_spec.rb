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

  describe "B10: cards que faltavam" do
    # Meio-dia: "daqui a 1 h" ainda é hoje (depois das 23 h a agenda virava amanhã e o CI falhava à noite).
    around { |ex| travel_to(Time.zone.now.change(hour: 12)) { ex.run } }

    it "termostato, umidificador, luz, botão, agenda, lista, diário, imagem, página, relógio e planta: validam, resolvem e desenham" do
      within(tenant) do
        create(:point, device: ac, name: "Temperatura ambiente", key: "ar.agora", capability: "measure", value: 26.5, unit: "°C", device_class: "temperature", data_type: "decimal")
      end
      hum = within(tenant) { create(:device, site: site, name: "Umidificador do quarto") }
      within(tenant) do
        create(:point, device: hum, name: "Umidade alvo", key: "um.alvo", capability: "setpoint", writable: true, value: 55, unit: "%", device_class: "humidity", data_type: "decimal")
        create(:point, device: hum, name: "Umidade", key: "um.agora", capability: "measure", value: 41, unit: "%", device_class: "humidity", data_type: "decimal")
      end
      lamp = within(tenant) { create(:device, site: site, name: "Luz da sala") }
      dim = within(tenant) { create(:point, device: lamp, name: "Brilho", key: "luz.brilho", capability: "dimmer", writable: true, value: 60, data_type: "integer") }
      script = within(tenant) { create(:point, device: create(:device, site: site, name: "Scripts"), name: "Teste noite", key: "s.noite", capability: "script", writable: true) }
      cal = within(tenant) do
        create(:point, device: create(:device, site: site, name: "Agenda"), name: "Família", key: "agenda.familia", capability: "calendar",
                       address: { "events" => [ { "summary" => "Teste dentista", "start" => 1.hour.from_now.iso8601, "end" => 2.hours.from_now.iso8601 },
                                                { "summary" => "Teste viagem", "start" => 1.day.from_now.beginning_of_day.iso8601, "end" => 2.days.from_now.beginning_of_day.iso8601, "all_day" => true } ] })
      end
      todo = within(tenant) do
        create(:point, device: create(:device, site: site, name: "Listas"), name: "Compras", key: "lista.compras", capability: "todo", helper: "todo", writable: true, value: 1, data_type: "integer",
                       attrs: { "items" => [ { "uid" => "u1", "summary" => "Leite", "status" => "needs_action" }, { "uid" => "u2", "summary" => "Pão", "status" => "completed" } ] })
      end
      plant = within(tenant) { create(:device, site: site, name: "Teste samambaia") }
      soil = within(tenant) { create(:point, device: plant, name: "Umidade do solo", key: "pl.solo", capability: "measure", value: 9, unit: "%", device_class: "moisture", data_type: "decimal") }
      lux = within(tenant) { create(:point, device: plant, name: "Luz", key: "pl.luz", capability: "measure", value: 9000, unit: "lx", data_type: "decimal") }

      widgets = [
        { "id" => "t", "type" => "thermostat", "bind" => power.id },
        { "id" => "h", "type" => "humidifier", "bind" => "um.alvo" },
        { "id" => "l", "type" => "light", "bind" => dim.id },
        { "id" => "b", "type" => "button", "bind" => script.id, "icon" => "moon" },
        { "id" => "c", "type" => "calendar", "binds" => [ cal.id ], "days" => 3 },
        { "id" => "td", "type" => "todo", "bind" => todo.id },
        { "id" => "lg", "type" => "logbook", "limit" => 5 },
        { "id" => "im", "type" => "image", "image" => "https://exemplo.com.br/sala.jpg", "aspect" => "4:3", "label" => "Sala", "tap_action" => { "action" => "navigate", "navigation_path" => "v1" } },
        { "id" => "if", "type" => "iframe", "url" => "https://exemplo.com.br/radar" },
        { "id" => "ck", "type" => "clock", "seconds" => "1", "size" => "large" },
        { "id" => "pl", "type" => "plant", "binds" => [ soil.id, lux.id ] }
      ]
      d = board(widgets)
      expect(Dashboards::Schema.errors(d.definition)).to eq([])
      res = resolved(d)["views"][0]["sections"][0]["widgets"].index_by { |w| w["id"] }
      expect(res["t"]["data"]).to include("target_id" => target.id, "value" => 23, "current" => 26.5, "mode" => "Refrigerar", "tone" => "cool", "on" => true)
      expect(res["h"]["data"]).to include("value" => 55, "current" => 41, "tone" => "humid", "min" => 30.0, "max" => 80.0, "ratio" => 0.5)
      expect(res["l"]["data"]).to include("target_id" => dim.id, "value" => 60, "tone" => "light", "ratio" => 0.6)
      expect(res["b"]["data"]).to include("command" => "run")
      expect(res["c"]["data"]["days"].map { |x| x["events"].map { |e| e["summary"] } }.flatten).to eq([ "Teste dentista", "Teste viagem" ])
      expect(res["c"]["data"]["days"].first["label"]).to eq("Hoje")
      expect(res["td"]["data"]["pending"].map { |i| i["summary"] }).to eq([ "Leite" ])
      expect(res["pl"]["data"]).to include("problem" => true)
      expect(res["pl"]["data"]["metrics"].map { |m| [ m["key"], m["status"] ] }).to eq([ %w[moisture low], %w[illuminance ok] ])
      expect(res["ck"]["data"]).to include("tz" => "America/Sao_Paulo", "seconds" => true, "size" => "large")

      get "/paineis/#{d.id}"
      body = response.body
      expect(body).to include("dw-dial dw-dial-cool", "Agora 26,5 °C", "dw-dial-humid", "dw-dial-light", "dw-btn", "Teste dentista", "Dia inteiro",
                              "Leite", %(aria-checked="true"), "Concluídos (1)", "https://exemplo.com.br/sala.jpg", "aspect-ratio: 4 / 3",
                              %(sandbox="allow-scripts allow-same-origin allow-forms allow-popups"), 'data-controller="dw-clock"', "Precisa de atenção: umidade", "Baixo")
    end

    it "recusa link inseguro na imagem e na página" do
      errs = Dashboards::Schema.errors(defn([ { "id" => "im", "type" => "image", "image" => "javascript:x" }, { "id" => "if", "type" => "iframe", "url" => "http://x.com" } ])).join(" | ")
      expect(errs).to include("image precisa ser https://", "url precisa começar com https://")
    end

    it "o editor cria os cards novos pelo formulário" do
      d = board([])
      %w[clock calendar logbook].each do |type|
        patch "/paineis/#{d.id}/rascunho", params: { op: "add_widget", target: "s1", view_id: "v1", widget: { type: type, days: "5", limit: "8", period: "7d", format: "12h", size: "small" } }
      end
      list = within(tenant) { d.reload.draft["views"][0]["sections"][0]["widgets"] }
      expect(list.map { |w| w["type"] }).to eq(%w[clock calendar logbook])
      expect(list[0]).to include("format" => "12h", "size" => "small")
      expect(list[1]).to include("days" => 5)
      expect(list[2]).to include("limit" => 8, "period" => "7d")
      expect(Dashboards::Schema.errors(within(tenant) { d.reload.draft })).to eq([])
    end
  end

  describe "B8: tipos de visão, subvisões e pilhas" do
    it "masonry, panel e sidebar desenham as mesmas seções de outro jeito; subvisão some das abas e tem voltar" do
      tile = ->(id) { { "id" => id, "type" => "tile", "bind" => power.id } }
      views = [
        { "id" => "m", "title" => "Mosaico", "type" => "masonry", "sections" => [ { "id" => "ms", "title" => "Luzes", "widgets" => [ tile.("m1"), tile.("m2") ] } ] },
        { "id" => "p", "title" => "Teste câmera", "path" => "camera", "type" => "panel", "subview" => true, "back_path" => "v1", "sections" => [ { "id" => "ps", "widgets" => [ tile.("p1") ] } ] },
        { "id" => "sb", "title" => "Lateral", "type" => "sidebar", "sections" => [ { "id" => "a", "widgets" => [ tile.("x1") ] }, { "id" => "b", "position" => "sidebar", "widgets" => [ tile.("x2") ] } ] }
      ]
      d = board([ tile.("w1") ], extra_views: views)
      expect(Dashboards::Schema.errors(d.definition)).to eq([])

      get "/paineis/#{d.id}"
      expect(response.body).to include("Mosaico", "Lateral")
      expect(response.body).not_to include("Teste câmera") # subvisão fora das abas
      get "/paineis/#{d.id}?view=m"
      expect(response.body).to include("dw-masonry", "dw-masonry-title")
      get "/paineis/#{d.id}?view=camera"
      expect(response.body).to include("dw-panel", "dw-back", "Teste câmera", "Voltar para Início")
      get "/paineis/#{d.id}?view=sb"
      expect(response.body).to include("dw-sidebar-main", "dw-sidebar-side")
    end

    it "recusa tipo de visão e posição desconhecidos" do
      bad = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "type" => "carrossel", "subview" => "sim", "sections" => [ { "id" => "s", "position" => "topo", "widgets" => [] } ] } ] }
      expect(Dashboards::Schema.errors(bad).join(" | ")).to include("tipo de visão desconhecido", "subview precisa ser", "position de seção")
    end

    it "pilha guarda widgets, resolve e desenha cada um no próprio quadro; o editor adiciona dentro e preserva" do
      stack = { "id" => "st", "type" => "stack", "direction" => "grid", "columns" => 3, "label" => "Teste pilha",
                "widgets" => [ { "id" => "c1", "type" => "tile", "bind" => power.id }, { "id" => "c2", "type" => "tile", "bind" => target.id } ] }
      d = board([ stack ])
      expect(Dashboards::Schema.errors(d.definition)).to eq([])
      w = first_widget(d)
      expect(w["widgets"].map { |c| c["data"]["point_ids"] }).to eq([ [ power.id ], [ target.id ] ])
      get "/paineis/#{d.id}"
      expect(response.body).to include("dw-stack dw-stack-grid", "--cols: 3", %(id="w_c1"), %(id="w_c2"))
      get "/paineis/#{d.id}/w/c2"
      expect(response.body).to include(%(id="w_c2"))

      nested = defn([ { "id" => "x", "type" => "tile", "bind" => power.id, "widgets" => [] } ])
      expect(Dashboards::Schema.errors(nested).join).to include("não guarda widgets")
      deep = defn([ { "id" => "a", "type" => "stack", "widgets" => [ { "id" => "b", "type" => "stack", "widgets" => [ { "id" => "c", "type" => "stack", "widgets" => [] } ] } ] } ])
      expect(Dashboards::Schema.errors(deep).join).to include("até 2 níveis")

      patch "/paineis/#{d.id}/rascunho", params: { op: "add_widget", target: "st", view_id: "v1", widget: { type: "clock" } }
      patch "/paineis/#{d.id}/rascunho", params: { op: "update_widget", target: "st", view_id: "v1", widget: { type: "stack", direction: "horizontal", label: "Teste pilha 2" } }
      patch "/paineis/#{d.id}/rascunho", params: { op: "move", kind: "widget", target: "c2", dir: "up", view_id: "v1" }
      draft = within(tenant) { d.reload.draft }
      st = draft["views"][0]["sections"][0]["widgets"][0]
      expect(st).to include("direction" => "horizontal", "label" => "Teste pilha 2")
      expect(st["widgets"].map { |c| c["type"] }).to eq(%w[tile tile clock])
      expect(st["widgets"].map { |c| c["id"] }.first(2)).to eq(%w[c2 c1])
      get "/paineis/#{d.id}/editar"
      expect(response.body).to include("Adicionar dentro", "Tipo de visão", "Subvisão")
    end

    it "o editor grava tipo, subvisão e o voltar da visão" do
      d = board([], extra_views: [ { "id" => "v2", "title" => "Teste quarto", "sections" => [] } ])
      patch "/paineis/#{d.id}/rascunho", params: { op: "update_view", target: "v2", view_id: "v2", title: "Teste quarto", view_type: "masonry", subview: "1", back_path: "v1" }
      v = within(tenant) { d.reload.draft["views"][1] }
      expect(v).to include("type" => "masonry", "subview" => true, "back_path" => "v1")
      patch "/paineis/#{d.id}/rascunho", params: { op: "update_view", target: "v2", view_id: "v2", title: "Teste quarto", view_type: "sections" }
      expect(within(tenant) { d.reload.draft["views"][1].keys }).not_to include("type", "subview", "back_path")
    end

    it "tipo de visão novo entra pelo registro (stub_const)" do
      fake = Class.new(Dashboards::ViewTypes::Base) do
        describe key: "carrossel_teste", label: "Carrossel (teste)", icon: "collection", description: "Teste"
        texts en: { label: "Carousel (test)", description: "Test" }, es: { label: "Carrusel (prueba)", description: "Prueba" }
        def self.partial = "web/dashboards/views/masonry"
      end
      stub_const("Dashboards::ViewTypes::CarrosselTeste", fake)
      stub_const("Dashboards::ViewTypes::PLUGINS", Dashboards::ViewTypes::PLUGINS + %w[CarrosselTeste])
      d = board([ { "id" => "w1", "type" => "tile", "bind" => power.id } ], view: { "type" => "carrossel_teste" })
      expect(Dashboards::Schema.errors(d.definition)).to eq([])
      get "/paineis/#{d.id}"
      expect(response.body).to include("dw-masonry")
      get "/paineis/#{d.id}/editar"
      expect(response.body).to include("Carrossel (teste)")
    end
  end

  describe "B11: temas do usuário e barra lateral por pessoa" do
    it "a casa cria um tema (cores, papel de parede, vidro, fonte); ele entra na galeria, valida no painel e pinta" do
      get "/configuracoes/aparencia"
      expect(response.body).to include("Meu tema", "Temas da casa", "Barra lateral", "Lista Clara", 'data-controller="theme-preview"')
      post "/configuracoes/aparencia/temas", params: { theme: { name: "Teste praia", accent: "#0EA5E9", accent2: "#f59e0b", wall_style: "mesh", glass: "1", font: "rounded" } }
      th = within(tenant) { DashboardTheme.last }
      expect(th).to have_attributes(name: "Teste praia", accent: "#0ea5e9", wall_style: "mesh", glass: true, font: "rounded")
      expect(th.key).to match(/\Au-[a-z0-9]{8}\z/)
      expect(th.css).to include("--accent: #0ea5e9", "--grad: linear-gradient(135deg, #0ea5e9 0%, #f59e0b 100%)", "--wall: radial-gradient", "--font-sans: ui-rounded")

      d = board([ { "id" => "w1", "type" => "tile", "bind" => power.id } ], view: { "theme" => { "key" => th.key } })
      expect(within(tenant) { Dashboards::Schema.errors(d.definition) }).to eq([])
      expect(resolved(d)["views"][0]["theme_now"]).to include("key" => th.key, "accent" => "#0ea5e9", "accent2" => "#f59e0b")
      get "/paineis/#{d.id}"
      expect(response.body).to include("dw-theme-#{th.key}", "--font-sans: ui-rounded")
      get "/paineis/#{d.id}/editar"
      expect(response.body).to include("Teste praia")

      post "/configuracoes/aparencia/temas", params: { theme: { name: "Teste ruim", accent: "red", accent2: "#000000", wall_style: "glow", font: "manrope" } }
      expect(within(tenant) { DashboardTheme.count }).to eq(1)
    end

    it "tema da pessoa vale por cima do painel, no perfil (web e app) ou só no aparelho" do
      d = board([ { "id" => "w1", "type" => "tile", "bind" => power.id } ], view: { "theme" => { "key" => "aurora" } })
      patch "/configuracoes/aparencia", params: { op: "my_theme", key: "oceano" }
      expect(within(tenant) { user.reload.dashboard_prefs["theme"] }).to eq("oceano")
      get "/paineis/#{d.id}"
      expect(response.body).to include("dw-theme-oceano")
      patch "/configuracoes/aparencia", params: { op: "device_theme", key: "grafite" }
      get "/paineis/#{d.id}"
      expect(response.body).to include("dw-theme-grafite")
      patch "/configuracoes/aparencia", params: { op: "device_theme", key: "" }
      patch "/configuracoes/aparencia", params: { op: "my_theme", key: "nada" } # chave que não existe = segue o painel
      get "/paineis/#{d.id}"
      expect(response.body).to include("dw-theme-aurora")

      headers = auth_headers(user)
      get "/api/v1/themes", headers: headers
      expect(response.parsed_body["data"].map { |t| t["key"] }).to include("lista", "aurora", "grafite")
      patch "/api/v1/me", params: { theme: "floresta" }, headers: headers
      expect(response.parsed_body.dig("data", "theme")).to eq("floresta")
      get "/api/v1/dashboards/#{d.id}", headers: headers
      expect(response.parsed_body.dig("data", "views", 0, "theme_now", "key")).to eq("floresta")
      patch "/api/v1/me", params: { theme: "voar" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "barra lateral por pessoa: esconde, reordena e restaura; Configurações fica" do
      get "/configuracoes/aparencia"
      expect(response.body).to include("Esconder Diário")
      patch "/configuracoes/aparencia", params: { op: "sidebar", item: "logbook", dir: "toggle" }
      patch "/configuracoes/aparencia", params: { op: "sidebar", item: "history", dir: "up" }
      patch "/configuracoes/aparencia", params: { op: "sidebar", item: "settings", dir: "toggle" }
      prefs = within(tenant) { user.reload.dashboard_prefs["sidebar"] }
      expect(prefs["hidden"]).to eq([ "logbook" ])
      expect(prefs["order"].index("history")).to be < prefs["order"].index("logbook")
      get "/configuracoes/aparencia"
      nav = response.body[/<nav class="ss-nav.*?<\/nav>/m]
      expect(nav).not_to include(">Diário<")
      expect(nav).to include("Configurações")
      expect(nav.index(">Histórico<")).to be < nav.index(">Notificações<")
      patch "/configuracoes/aparencia", params: { op: "sidebar_reset" }
      expect(within(tenant) { user.reload.dashboard_prefs }).not_to have_key("sidebar")
    end
  end

  describe "B12: painel de energia completo" do
    it "gás e água em m³ (litro vira m³), CO2 e previsão solar no fluxo, e o painel pronto monta tudo" do
      travel_to(Time.zone.parse("2026-11-02 15:30")) do
        gas = within(tenant) { create(:point, device: create(:device, site: site, name: "Teste gás"), name: "Gás", key: "gas.m3", capability: "measure", unit: "m³", data_type: "decimal", value: 12.5) }
        water = within(tenant) { create(:point, device: create(:device, site: site, name: "Teste água"), name: "Água", key: "agua.l", capability: "measure", unit: "L", data_type: "decimal", value: 2500) }
        grid = within(tenant) { create(:point, device: create(:device, site: site, name: "Teste rede"), name: "Rede", key: "rede.w", capability: "measure", unit: "W", data_type: "decimal", value: 800) }
        co2 = within(tenant) { create(:point, device: grid.device, name: "Fóssil", key: "rede.co2", capability: "measure", unit: "%", data_type: "decimal", value: 18) }
        fc = within(tenant) { create(:point, device: grid.device, name: "Previsão", key: "solar.prev", capability: "measure", unit: "kWh", data_type: "decimal", value: 21.4) }
        day = Time.zone.parse("2026-11-02 00:00")
        [ [ gas, 10.0, 12.0 ], [ water, 1000.0, 2000.0 ] ].each do |p, a, b|
          within(tenant) { ReadingRollup.create!(point_id: p.id, bucket: "1h", starts_at: day + 1.hour, min: a, max: a, avg: a, last: a, count: 1) }
          within(tenant) { ReadingRollup.create!(point_id: p.id, bucket: "1h", starts_at: day + 10.hours, min: b, max: b, avg: b, last: b, count: 1) }
        end
        d = board([ { "id" => "g", "type" => "utility", "kind" => "gas", "binds" => [ gas.id ], "period" => "today", "tariff" => 8.0 },
                    { "id" => "a", "type" => "utility", "binds" => [ water.id ], "period" => "today" },
                    { "id" => "f", "type" => "energy_flow", "grid" => grid.id, "co2" => co2.id, "solar_forecast" => fc.id } ])
        expect(Dashboards::Schema.errors(d.definition)).to eq([])
        res = resolved(d)["views"][0]["sections"][0]["widgets"].index_by { |w| w["id"] }
        expect(res["g"]["data"]).to include("unit" => "m³", "kind" => "gas", "kwh" => 2.5, "cost" => 20.0)
        expect(res["a"]["data"]).to include("kind" => "water", "kwh" => 1.5)
        expect(res["f"]["data"]).to include("fossil_pct" => 18, "forecast_kwh" => 21.4)
        get "/paineis/#{d.id}"
        expect(response.body).to include("2,5 m³", "Gás", "Água", "82% da rede sem fóssil", "Previsão solar hoje: 21,4 kWh")

        preset = within(tenant) { Dashboards::Presets::EnergyPreset.build(site, ActionController::Parameters.new(grid: grid.id, gas: gas.id, water: water.id, gas_tariff: "8", co2: co2.id, solar_forecast: fc.id)) }
        all = preset["views"][0]["sections"].flat_map { |s| s["widgets"] }
        expect(all.select { |w| w["type"] == "utility" }.map { |w| w["kind"] }).to eq(%w[gas water])
        expect(all.find { |w| w["type"] == "energy_flow" }).to include("co2" => co2.id, "solar_forecast" => fc.id)
        expect(within(tenant) { Dashboards::Schema.errors(preset) }).to eq([])
      end
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
