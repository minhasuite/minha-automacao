require "rails_helper"

# Experiência do dia a dia (ideias 9 a 13 e 23 da proposta de personalização):
# painel por contexto (sol, presença, ordem e visão que abre), painel por
# aparelho, link de convidado, ações em lote, busca e favoritos, e o painel
# "Saúde da casa".
RSpec.describe "Experiência do painel" do
  let(:user) { create(:user, name: "Ana Souza") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa", latitude: -23.55, longitude: -46.63, timezone: "America/Sao_Paulo") } }
  let!(:sala) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let!(:quarto) { within(tenant) { create(:area, site: site, name: "Quarto") } }
  let!(:quadro) { within(tenant) { create(:device, site: site, area: sala, name: "Quadro da sala") } }
  let!(:teto) { within(tenant) { create(:point, device: quadro, name: "Teto", value: true, writable: true) } }
  let!(:abajur) { within(tenant) { create(:point, device: quadro, name: "Abajur", value: true, writable: true, risk: "sensitive") } }
  let!(:portao) { within(tenant) { create(:point, device: quadro, name: "Portão", value: true, writable: true, risk: "critical") } }
  let!(:luz_quarto) { within(tenant) { create(:point, device: create(:device, site: site, area: quarto, name: "Quarto"), name: "Luz do quarto", value: true, writable: true) } }
  let!(:temp) { within(tenant) { create(:point, device: quadro, name: "Temperatura", capability: "measure", unit: "°C", value: 24) } }

  let(:helpers) { within(tenant) { create(:device, site: site, name: "Helpers", external_id: "helpers") } }
  let(:zone) { within(tenant) { create(:point, device: helpers, name: "Casa", capability: "text", helper: "zone", address: { "home" => true }) } }
  let(:area_card) do
    { "id" => "ac", "type" => "area_card", "area" => sala.id, "guest" => true,
      "quick_actions" => [ { "action" => "command_query", "label" => "Apagar tudo", "query" => "capability=onoff state=on", "command" => "off" } ] }
  end
  let(:defn) do
    { "schema_version" => 1,
      "open_if" => [ { "when" => { "presence" => { "home" => "nobody" } }, "view" => "fora" } ],
      "views" => [
        { "id" => "home", "title" => "Início",
          "order_if" => [ { "when" => { "sun" => { "is" => "night" } }, "first" => %w[s-noite] } ],
          "sections" => [
            { "id" => "s-dia", "title" => "Dia", "widgets" => [ area_card, { "id" => "t-temp", "type" => "tile", "bind" => temp.id } ] },
            { "id" => "s-noite", "title" => "Noite", "widgets" => [
              { "id" => "t-teto", "type" => "tile", "bind" => teto.id, "guest" => true },
              { "id" => "t-portao", "type" => "tile", "bind" => portao.id, "guest" => true },
              { "id" => "t-quarto", "type" => "tile", "bind" => luz_quarto.id, "visible_if" => { "sun" => { "after" => "sunset", "before" => "sunrise" } } }
            ] }
          ] },
        { "id" => "fora", "path" => "fora", "title" => "Fora de casa", "sections" => [ { "id" => "s-fora", "widgets" => [ { "id" => "t-fora", "type" => "tile", "bind" => teto.id } ] } ] }
      ] }
  end
  let!(:dashboard) { within(tenant) { site.dashboards.create!(name: "Casa", kind: "custom", definition: defn).tap { _1.publish!(defn, author: user) } } }
  let(:noon) { Time.zone.parse("2026-11-11 12:00 -03:00") }
  let(:night) { Time.zone.parse("2026-11-11 23:00 -03:00") }

  def person(name, where) = within(tenant) { create(:point, device: helpers, name: name, capability: "text", helper: "person", value: where) }



  def resolve(role: "owner") = within(tenant) { Dashboards::Resolver.new(dashboard, role: role).call }
  def widget(res, id) = Dashboards::Resolver.flatten(res["views"].flat_map { |v| [ *v["badges"], *v["sections"].flat_map { _1["widgets"] } ] }).find { _1["id"] == id }
  def login(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  describe "painel por contexto (ideia 9)" do
    it "ordena as seções e mostra widgets pelo sol" do
      day = travel_to(noon) { resolve }
      expect(day["views"].first["sections"].pluck("id")).to eq(%w[s-dia s-noite])
      expect(widget(day, "t-quarto")["visible"]).to be(false)

      dark = travel_to(night) { resolve }
      expect(dark["views"].first["sections"].pluck("id")).to eq(%w[s-noite s-dia])
      expect(dark["views"].first["order_now"]).to eq(%w[s-noite])
      expect(widget(dark, "t-quarto")["visible"]).to be(true)
    end

    it "sem latitude, o dia vai das 6h às 18h" do
      within(tenant) { site.update!(latitude: nil, longitude: nil) }
      r = within(tenant) { Dashboards::Resolver.new(dashboard.reload, role: "owner") }
      travel_to(Time.zone.parse("2026-11-11 17:30 -03:00")) { expect(within(tenant) { r.condition?({ "sun" => { "is" => "day" } }) }).to be(true) }
      travel_to(Time.zone.parse("2026-11-11 18:30 -03:00")) { expect(within(tenant) { r.condition?({ "sun" => { "is" => "day" } }) }).to be(false) }
    end

    it "abre a visão pela presença (open_if) e a URL ainda escolhe" do
      zone
      ana = person("Ana", "Casa")
      expect(travel_to(noon) { resolve }["open_view"]).to be_nil
      within(tenant) { ana.update_columns(value: "Fora") }
      res = travel_to(noon) { resolve }
      expect(res["open_view"]).to eq("fora")
      expect(Dashboards.pick_view(res, nil)["id"]).to eq("fora")
      expect(Dashboards.pick_view(res, "home")["id"]).to eq("home")

      r = within(tenant) { Dashboards::Resolver.new(dashboard, role: "owner") }
      within(tenant) do
        expect(r.condition?({ "presence" => { "home" => "anyone" } })).to be(false)
        expect(r.condition?({ "presence" => { "home" => "everyone" } })).to be(false)
        expect(r.condition?({ "presence" => { "person" => ana.id, "home" => false } })).to be(true)
      end

      login
      travel_to(noon) { get "/paineis/#{dashboard.id}" }
      expect(response.body).to include("Fora de casa")
    end

    it "presença entra nas dependências do tempo real" do
      zone
      ana = person("Ana", "Casa")
      defn["views"][1]["sections"][0]["widgets"][0]["visible_if"] = { "presence" => { "home" => "anyone" } }
      within(tenant) { dashboard.publish!(defn, author: user) }
      expect(widget(resolve, "t-fora")["deps"]).to include(ana.id)
    end

    it "valida sol, presença, order_if e open_if" do
      bad = defn.deep_dup
      bad["open_if"] = [ { "when" => { "role" => [ "owner" ] }, "view" => "x y" } ]
      bad["views"][0]["order_if"] = []
      bad["views"][0]["sections"][0]["widgets"][1]["visible_if"] = { "sun" => { "is" => "dusk" }, "presence" => { "home" => "maybe" } }
      errors = Dashboards::Schema.errors(bad).join(" | ")
      expect(errors).to include("sun:", "presence:", "1 a 10 regras", "\"view\" é o id", "não aceita role")
      expect(Dashboards::Schema.errors(defn)).to eq([])
    end
  end

  describe "ações em lote (ideia 12)" do
    it "resolve o botão com a contagem e manda o comando só ao que o papel comanda, nunca ao crítico" do
      w = widget(resolve, "ac")
      expect(w["quick"].first).to include("action" => "command_query", "label" => "Apagar tudo", "slot" => "quick-0", "count" => 2, "allowed" => 2, "can_command" => true)
      expect(w["quick"].first["confirm"]).to include("2 ponto")

      login
      get "/paineis/#{dashboard.id}"
      expect(response.body).to include("Apagar tudo", "/paineis/#{dashboard.id}/w/ac/lote")
      post "/paineis/#{dashboard.id}/w/ac/lote", params: { slot: "quick-0" }
      expect(flash[:notice]).to eq("2 comandos enviados")
      expect([ teto, abajur, portao, luz_quarto ].map { _1.reload.value }).to eq([ false, false, true, true ])
      expect(within(tenant) { Command.where(source: "web").pluck(:point_id) }).to contain_exactly(teto.id, abajur.id)
    end

    it "papel baixo pula o sensível; lugar sem lote dá 404; API devolve a conta" do
      guest = create(:user, tenant: tenant, role: "member")
      within(tenant) { create(:site_membership, site: site, user: guest, role: "guest") }
      expect(widget(resolve(role: "guest"), "ac")["quick"].first).to include("count" => 2, "allowed" => 1)

      post "/api/v1/dashboards/#{dashboard.id}/widgets/ac/batch", params: { slot: "quick-0" }, headers: auth_headers(guest)
      expect(response).to have_http_status(:ok)
      expect(data).to include("sent" => 1, "skipped" => 1, "failed" => [])
      expect(abajur.reload.value).to be(true)

      post "/api/v1/dashboards/#{dashboard.id}/widgets/t-temp/batch", params: { slot: "tap" }, headers: auth_headers(guest)
      expect(response).to have_http_status(:not_found)
    end

    it "botão padrão do cartão de área vem dos Padrões do local" do
      login
      patch "/configuracoes/paineis/padroes/#{site.id}", params: { quick: { "0" => { label: "Apagar luzes", query: "capability=onoff state=on", command: "off" } } }
      expect(within(tenant) { site.reload.settings.dig("dashboard_defaults", "quick_actions", "area_card") }).to eq([ { "action" => "command_query", "label" => "Apagar luzes", "query" => "capability=onoff state=on", "command" => "off" } ])
      get "/configuracoes/paineis/padroes/#{site.id}"
      expect(response.body).to include("Apagar luzes")

      card = { "id" => "ac2", "type" => "area_card", "area" => quarto.id }
      d2 = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => [ card ] } ] } ] }
      within(tenant) { dashboard.publish!(d2, author: user) }
      expect(widget(resolve, "ac2")["quick"].first).to include("label" => "Apagar luzes", "count" => 1)

      patch "/configuracoes/paineis/padroes/#{site.id}", params: { quick: { "0" => { label: "x", query: "nada=1", command: "off" } } }
      expect(flash[:alert]).to be_present
    end

    it "lote também serve de gesto (toque segurado) e valida a ação" do
      a = { "action" => "command_query", "query" => { "capability" => "onoff", "state" => "on" }, "command" => "off" }
      expect(Dashboards::Actions.errors({ "hold_action" => a })).to eq([])
      expect(Dashboards::Actions.errors({ "hold_action" => a.merge("query" => "x=1") }).first).to include("command_query")
      expect(Dashboards::Actions.errors({ "quick_actions" => [ a ] }).first).to include("label")
      expect(Dashboards::Actions.errors({ "quick_actions" => [] }).first).to include("1 a 4")
      expect(Dashboards::Actions.errors({ "quick_actions" => [ { "action" => "nada" } ] }).first).to be_present
    end
  end

  describe "busca e favoritos (ideia 13)" do
    it "favorita pela web e pela API e o painel mostra a linha e a busca" do
      login
      post "/pontos/#{teto.id}/favorito"
      expect(flash[:notice]).to include("Teto")
      expect(user.reload.dashboard_prefs.dig("favorites", site.id)).to eq([ teto.id ])

      get "/paineis/#{dashboard.id}"
      body = response.body
      expect(body).to include("Favoritos", 'data-controller="ss-filter"', 'data-ss-filter-target="item"', "Buscar no painel")
      expect(body).to match(/data-ss-filter-text="[^"]*Teto/)

      put "/api/v1/points/#{temp.id}/favorite", params: { favorite: true }, headers: auth_headers(user)
      expect(data).to include("favorite" => true, "favorites" => [ teto.id, temp.id ])
      get "/api/v1/dashboards/#{dashboard.id}", headers: auth_headers(user)
      expect(data["favorites_now"]).to eq([ teto.id, temp.id ])
      expect(data["points"][temp.id]).to include("name" => "Temperatura")
      expect(data["views"].first["sections"].first["widgets"].first["search"]).to include("Sala")

      put "/api/v1/points/#{teto.id}/favorite", params: { favorite: false }, headers: auth_headers(user)
      expect(data["favorites"]).to eq([ temp.id ])
      get "/pontos/#{temp.id}"
      expect(response.body).to include("Favorito")
    end

    it "painel com favorites: false não mostra a linha" do
      within(tenant) { Dashboards::Personal.toggle!(user, teto) }
      p = resolve.merge("favorites" => false)
      expect(within(tenant) { Dashboards::Personal.apply!(p, site: site, user: user, role: "owner") }).not_to have_key("favorites_now")
    end
  end

  describe "painel por aparelho (ideia 10)" do
    let!(:outro) { within(tenant) { site.dashboards.create!(name: "Parede", kind: "custom", definition: defn).tap { _1.publish!(defn, author: user) } } }

    it "dá nome a este navegador e o Início abre o painel e a visão escolhidos" do
      login
      get "/configuracoes/paineis/aparelhos"
      expect(response.body).to include("Este aparelho", "Parede")
      post "/configuracoes/paineis/aparelhos", params: { panel_device: { name: "Tablet da cozinha", dashboard_id: outro.id, view: "fora" } }
      device = within(tenant) { PanelDevice.last }
      expect(device).to have_attributes(name: "Tablet da cozinha", kind: "web", dashboard_id: outro.id, view: "fora", user_id: user.id)
      expect(cookies[:ma_device]).to be_present

      travel_to(noon) { get "/" }
      expect(response.body).to include("Fora de casa", "/paineis/#{outro.id}/w/t-fora")
      get "/configuracoes/paineis/aparelhos"
      expect(response.body).to include("este aparelho")

      patch "/configuracoes/paineis/aparelhos/#{device.id}", params: { panel_device: { name: "Tablet", dashboard_id: "outra-coisa", view: "" } }
      expect(device.reload).to have_attributes(name: "Tablet", dashboard_id: nil, view: nil)
      delete "/configuracoes/paineis/aparelhos/#{device.id}"
      expect(within(tenant) { PanelDevice.count }).to eq(0)
      expect(AuditEvent.where(auditable_type: "PanelDevice").pluck(:action)).to include("create", "update", "destroy")
    end

    it "o app manda X-MA-Device: o padrão e a visão vêm do aparelho; a tela do servidor reconhece" do
      within(tenant) { PanelDevice.create!(key: "app:instalacao-123", kind: "app", name: "Celular", dashboard: outro, view: "fora", user: user) }
      headers = auth_headers(user).merge("X-MA-Device" => "instalacao-123")
      get "/api/v1/sites/#{site.id}/dashboards", headers: headers
      mine = data.find { _1["id"] == outro.id }
      expect(mine).to include("default" => true, "device_default" => true)
      get "/api/v1/dashboards/#{outro.id}", headers: headers
      expect(data["open_view"]).to eq("fora")

      get "/api/v1/screen", params: { path: "/configuracoes/paineis/aparelhos" }, headers: headers
      expect(response.body).to include("Celular")
    end

    it "membro não mexe no aparelho de outra pessoa; o painel que ele não vê não vale" do
      member = create(:user, tenant: tenant, role: "member")
      within(tenant) do
        create(:site_membership, site: site, user: member, role: "resident")
        outro.update!(roles: [ "owner" ])
      end
      dev = within(tenant) { PanelDevice.create!(key: "web:abcdefghij", name: "Do dono", dashboard: outro, user: user) }
      login(member)
      patch "/configuracoes/paineis/aparelhos/#{dev.id}", params: { panel_device: { name: "Meu" } }
      expect(response).to have_http_status(:not_found)
      expect(within(tenant) { Dashboard.default_for(site, member, "resident", device: dev) }).to eq(dashboard)
    end
  end

  describe "link de convidado (ideia 11)" do
    def create_link(role)
      login
      post "/configuracoes/paineis/convidados", params: { guest_link: { dashboard_id: dashboard.id, name: "Babá", role: role, hours: 8 } }
      response.body[%r{/convidado/[A-Za-z0-9_-]+}]
    end

    it "dono cria; o link mostra só os cartões marcados, comanda o comum e nunca o crítico; revogar corta" do
      url = create_link("guest")
      expect(url).to be_present
      link = within(tenant) { GuestLink.last }
      expect(link).to have_attributes(name: "Babá", role: "guest", created_by_id: user.id)
      expect(link.expires_at).to be_within(1.minute).of(8.hours.from_now)

      reset!
      get url
      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include("Teto", "Portão", "Babá")
      expect(body).not_to include("Temperatura", "Luz do quarto", "ss-shell")
      expect(link.reload.uses).to eq(1)

      post "#{url}/comando", params: { point_id: teto.id, command: "toggle" }
      expect(teto.reload.value).to be(false)
      expect(within(tenant) { Command.last }).to have_attributes(source: "guest", user_id: nil)
      expect(AuditEvent.where(auditable_type: "GuestLink", action: "command").count).to eq(1)

      post "#{url}/comando", params: { point_id: portao.id, command: "toggle" }
      expect(flash[:alert]).to eq("Este link não pode fazer isso.")
      expect(portao.reload.value).to be(true)
      post "#{url}/comando", params: { point_id: temp.id, command: "toggle" }
      expect(response).to have_http_status(:not_found)

      within(tenant) { link.revoke! }
      get url
      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("Link inválido")
    end

    it "leitor só vê; vencido não abre; quem não é dono não cria nem revoga" do
      url = create_link("viewer")
      reset!
      post "#{url}/comando", params: { point_id: teto.id, command: "toggle" }
      expect(teto.reload.value).to be(true)

      travel_to(9.hours.from_now) { get url }
      expect(response).to have_http_status(:not_found)

      member = create(:user, tenant: tenant, role: "member")
      within(tenant) { create(:site_membership, site: site, user: member, role: "technician") }
      login(member)
      get "/configuracoes/paineis/convidados"
      expect(response.body).to include("Só o dono do local")
      post "/configuracoes/paineis/convidados", params: { guest_link: { dashboard_id: dashboard.id, name: "X", role: "guest" } }
      expect(response).to have_http_status(:not_found)
      delete "/configuracoes/paineis/convidados/#{within(tenant) { GuestLink.last.id }}"
      expect(response).to have_http_status(:not_found)
    end

    it "dono revoga pela tela e fica na auditoria" do
      create_link("guest")
      link = within(tenant) { GuestLink.last }
      get "/configuracoes/paineis/convidados"
      expect(response.body).to include("Babá", "Revogar")
      delete "/configuracoes/paineis/convidados/#{link.id}"
      expect(link.reload.revoked_at).to be_present
      expect(AuditEvent.where(auditable_type: "GuestLink").pluck(:action)).to include("create", "update")
    end
  end

  describe "Saúde da casa (ideia 23)" do
    it "monta o painel pronto clicável com sem sinal, bateria, Wi-Fi e o Sistema" do
      within(tenant) do
        create(:point, device: quadro, name: "Bateria do sensor", capability: "measure", unit: "%", device_class: "battery", value: 9)
        create(:point, device: quadro, name: "Sinal", capability: "measure", unit: "dBm", device_class: "signal_strength", value: -82)
        teto.update_columns(quality: "unavailable")
        sys = create(:device, site: site, name: "Sistema", external_id: "system:x")
        create(:point, device: sys, name: "Falhas em 24 h", capability: "measure", value: 3, address: { "field" => "failed_24h" })
      end
      login
      get "/locais/#{site.id}/paineis/prontos"
      expect(response.body).to include("Saúde da casa")
      post "/locais/#{site.id}/paineis/prontos/health", params: { preset: { name: "Saúde", battery: "15" } }
      d = within(tenant) { Dashboard.find_by!(name: "Saúde") }
      expect(Dashboards::Schema.errors(d.definition)).to eq([])
      expect(d.definition["favorites"]).to be(false)
      res = within(tenant) { Dashboards::Resolver.new(d, role: "owner").call }
      badges = res["views"].first["badges"].index_by { _1["id"] }
      expect(badges["hl-b-offline"]["data"]).to include("caption" => "1 sem sinal")
      expect(badges["hl-b-battery"]["data"]).to include("caption" => "1 bateria baixa")
      expect(badges["hl-b-wifi"]["data"]["drill_url"]).to be_present
      expect(widget(res, "hl-failed-24h")).to be_present

      get "/paineis/#{d.id}"
      expect(response.body).to include("Bateria do sensor", "Sinal", "Falhas em 24 h")
    end
  end

  it "zerar e exportar levam aparelhos e links" do
    within(tenant) do
      PanelDevice.create!(key: "web:abcdefghij", name: "Tablet")
      GuestLink.generate!(site: site, dashboard: dashboard, name: "Babá", role: "viewer", hours: 2, created_by: user)
    end
    export = Accounts::ExportData.call(tenant, user)
    expect(export[:panel_devices].size).to eq(1)
    expect(export[:guest_links].first).not_to have_key("token_digest")
    Accounts::WipeData.call(tenant)
    expect(within(tenant) { [ PanelDevice.count, GuestLink.count ] }).to eq([ 0, 0 ])
  end
end
