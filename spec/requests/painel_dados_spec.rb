require "rails_helper"

# Painel aberto por dado (proposta de personalização): itens do cartão de área
# como consultas (P1.1), estilo condicional (P1.2), topo da visão e selos com
# plural (P1.4), lista dos pontos de um número (ideia 14) e o selo de "dado
# velho" (ideia 22).
RSpec.describe "Painel por dado" do
  let(:user) { create(:user, name: "Ana Souza") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:sala) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let!(:quarto) { within(tenant) { create(:area, site: site, name: "Quarto") } }
  let!(:aparelho) { within(tenant) { create(:device, site: site, area: sala, name: "Quadro da sala") } }
  let!(:luz1) { within(tenant) { create(:point, device: aparelho, name: "Teto", value: true) } }
  let!(:luz2) { within(tenant) { create(:point, device: aparelho, name: "Abajur", value: true) } }
  let!(:porta) { within(tenant) { create(:point, device: aparelho, name: "Porta", capability: "contact", value: true) } }
  let!(:potencia) { within(tenant) { create(:point, device: aparelho, name: "Potência", capability: "measure", unit: "W", device_class: "power", value: 87.4) } }
  let!(:sem_sinal) { within(tenant) { create(:point, device: aparelho, name: "Fita", value: false, quality: "unavailable", reported_at: 3.hours.ago) } }
  let!(:temp) do
    within(tenant) { create(:point, device: aparelho, name: "Temperatura", capability: "measure", unit: "°C", device_class: "temperature", value: 24, reported_at: 6.hours.ago) }
  end
  # O que não existe não conta: aparelho desativado e aparelho removido da conta (varredura).
  let!(:desativado) { within(tenant) { create(:device, site: site, area: sala, name: "Velho", disabled: true) } }
  let!(:removido) { within(tenant) { create(:device, site: site, area: sala, name: "Queimado", removed_at: 1.day.ago) } }
  let!(:fantasma1) { within(tenant) { create(:point, device: desativado, name: "Luz velha", value: true, quality: "unavailable") } }
  let!(:fantasma2) { within(tenant) { create(:point, device: removido, name: "Luz queimada", value: true, quality: "unavailable") } }

  let(:card) { { "id" => "ac", "type" => "area_card", "area" => sala.id } }
  let(:defn) do
    { "schema_version" => 1, "views" => [
      { "id" => "home", "title" => "Início",
        "badges" => [ { "id" => "b-on", "type" => "stat", "label" => "ligados", "query" => { "capability" => "onoff", "state" => "on" }, "aggregate" => "count",
                        "labels" => { "zero" => "Nada ligado", "one" => "%{count} ligado", "other" => "%{count} ligados" } } ],
        "sections" => [ { "id" => "s1", "widgets" => [ card, { "id" => "t-temp", "type" => "tile", "bind" => temp.id },
                                                       { "id" => "t-porta", "type" => "tile", "bind" => porta.id, "label" => "Porta",
                                                         "style_if" => [ { "when" => { "state" => { "point" => porta.id, "is" => "true" } }, "tone" => "danger", "badge" => "Aberta",
                                                                           "label" => "Porta aberta", "color" => "danger" } ] } ] } ] }
    ] }
  end
  let!(:dashboard) { within(tenant) { site.dashboards.create!(name: "Casa", kind: "custom", definition: defn).tap { _1.publish!(defn, author: user) } } }

  def resolve(d = dashboard) = within(tenant) { Dashboards::Resolver.new(d, role: "owner").call }
  def widget(res, id) = Dashboards::Resolver.flatten(res["views"].flat_map { |v| [ *v["badges"], *v["sections"].flat_map { _1["widgets"] } ] }).find { _1["id"] == id }
  def login = post("/entrar", params: { email: user.email, password: "12345678" })

  describe "o que existe (Points::Query)" do
    it "não conta ponto de aparelho desativado nem removido" do
      ids = within(tenant) { Points::Query.new(site).call({ "area" => sala.id }).map(&:id) }
      expect(ids).to include(luz1.id, sem_sinal.id)
      expect(ids).not_to include(fantasma1.id, fantasma2.id)
    end
  end

  describe "cartão de área (P1.1)" do
    it "resolve o padrão do local como fatos prontos, com o plural, o tom e o caminho da lista" do
      d = widget(resolve, "ac")["data"]
      facts = d["facts"].index_by { _1["id"] }
      expect(facts.keys).to eq(%w[on open power offline]) # movimento não aparece (nenhum)
      expect(facts["on"]).to include("text" => "2 ligados", "icon" => "light-bulb", "value" => 2)
      expect(facts["open"]["text"]).to eq("1 aberto")
      expect(facts["power"]).to include("text" => "87,4 W", "num" => true)
      expect(facts["offline"]).to include("text" => "1 sem sinal", "tone" => "warn")
      expect(facts["offline"]["url"]).to eq("/paineis/#{dashboard.id}/w/ac/pontos?item=offline")
      # App antigo: as chaves de antes saem dos fatos de mesmo id.
      expect(d).to include("on" => 2, "open" => 1, "motion" => false, "power" => 87.4, "unavailable" => 1, "total" => 6)
      expect(widget(resolve, "ac")["deps"]).to include(luz1.id, sem_sinal.id)
      expect(widget(resolve, "ac")["deps"]).not_to include(fantasma1.id)
    end

    it "usa os itens do próprio widget e o padrão gravado no local" do
      own = card.merge("facts" => [ { "id" => "luzes", "label" => { "one" => "Uma luz", "other" => "%{count} luzes" }, "query" => { "capability" => "onoff" },
                                      "show" => "always", "tone" => "info" } ])
      defn2 = defn.deep_dup.tap { _1["views"][0]["sections"][0]["widgets"][0] = own }
      expect(Dashboards::Schema.errors(defn2)).to eq([])
      res = within(tenant) { Dashboards::Resolver.new(dashboard, role: "owner", definition: defn2).call }
      expect(widget(res, "ac")["data"]["facts"]).to eq([ { "id" => "luzes", "text" => "3 luzes", "tone" => "info", "value" => 3, "count" => 3,
                                                          "url" => "/paineis/#{dashboard.id}/w/ac/pontos?item=luzes" } ])

      within(tenant) { site.update!(settings: { "dashboard_defaults" => { "area_facts" => [ { "id" => "q", "label" => "%{count} no quarto", "query" => { "capability" => "onoff" } } ] } }) }
      expect(widget(resolve, "ac")["data"]["facts"].map { _1["text"] }).to eq([ "3 no quarto" ])
    end

    it "valida os itens" do
      bad = defn.deep_dup.tap { _1["views"][0]["sections"][0]["widgets"][0] = card.merge("facts" => [ { "id" => "X Y", "query" => { "nada" => 1 }, "aggregate" => "median" } ]) }
      errs = Dashboards::Schema.errors(bad).join(" | ")
      expect(errs).to include("id único").and include("consulta").and include("conta desconhecida")
    end
  end

  describe "estilo condicional (P1.2)" do
    it "a primeira regra que bate troca rótulo, cor, tom e selo, e o ponto vira dependência" do
      w = widget(resolve, "t-porta")
      expect(w).to include("label" => "Porta aberta", "color" => "danger", "style" => { "tone" => "danger", "badge" => "Aberta" })
      expect(w["deps"]).to include(porta.id)
      within(tenant) { porta.update!(value: false) }
      expect(widget(resolve, "t-porta")).not_to have_key("style")
    end

    it "valida regra, tom e cor; aceita os tokens do tema" do
      bad = defn.deep_dup
      bad["views"][0]["sections"][0]["widgets"][2]["style_if"] = [ { "when" => { "role" => [ "owner" ] }, "tone" => "roxo" }, { "x" => 1 } ]
      errs = Dashboards::Schema.errors(bad).join(" | ")
      expect(errs).to include("o tom é").and include("só aceita")
      ok = defn.deep_dup.tap { _1["views"][0]["sections"][0]["widgets"][1]["color"] = "warn" }
      expect(Dashboards::Schema.errors(ok)).to eq([])
    end
  end

  describe "dado velho (ideia 22)" do
    it "o ponto de temperatura parado há mais que o limite ganha o selo; 0 no widget desliga" do
      w = widget(resolve, "t-temp")
      expect(w["stale"]).to include("point_ids" => [ temp.id ])
      expect(w["stale"]["text"]).to start_with("Sem leitura: há")
      expect(widget(resolve, "t-porta")).not_to have_key("stale") # contato só fala quando muda: sem limite

      off = defn.deep_dup.tap { _1["views"][0]["sections"][0]["widgets"][1]["stale_after_min"] = 0 }
      res = within(tenant) { Dashboards::Resolver.new(dashboard, role: "owner", definition: off).call }
      expect(widget(res, "t-temp")).not_to have_key("stale")

      within(tenant) { site.update!(settings: { "dashboard_defaults" => { "stale_after_min" => { "temperature" => 600 } } }) }
      expect(widget(resolve, "t-temp")).not_to have_key("stale")
    end
  end

  describe "topo e selos (P1.4)" do
    it "selo pela contagem, sem singular inventado" do
      b = resolve["views"][0]["badges"].first
      expect(b["data"]).to include("caption" => "2 ligados", "drill_url" => "/paineis/#{dashboard.id}/w/b-on/pontos")
      within(tenant) { [ luz1, luz2 ].each { _1.update!(value: false) } }
      expect(resolve["views"][0]["badges"].first["data"]["caption"]).to eq("Nada ligado")
    end

    it "hero com Liquid, saudação e esconder" do
      payload = within(tenant) { Dashboards::Hero.apply!(resolve, site: site, user: user) }
      expect(payload["views"][0]["hero_now"]["title"]).to match(/, Ana\z/)
      expect(payload["views"][0]["hero_now"]["kicker"]).to start_with("Casa · ")
      view = { "title" => "Sala", "hero" => { "title" => "{{ 1 | plus: 2 }} coisas", "kicker" => "Praia", "greeting" => true } }
      expect(within(tenant) { Dashboards::Hero.resolve(view, site: site, user: user) }).to eq("title" => "3 coisas", "kicker" => "Praia")
      expect(Dashboards::Hero.resolve({ "hero" => { "hide" => true } }, site: site, user: user)).to eq("hide" => true)
      expect(Dashboards::Hero.errors({ "title" => "{{ x", "hide" => "sim", "y" => 1 }).size).to eq(3)
    end

    it "web e API mostram o topo resolvido, o selo e os itens tocáveis" do
      login
      get "/paineis/#{dashboard.id}"
      expect(response).to have_http_status(:ok)
      html = Nokogiri::HTML(response.body)
      expect(html.text).to include("2 ligados")
      expect(html.text).not_to include("Nenhum")
      expect(html.at_css("a.ss-hero-chip")["href"]).to eq("/paineis/#{dashboard.id}/w/b-on/pontos")
      expect(html.at_css("a.ss-mosaic-fact[href$='item=offline']").text).to include("1 sem sinal")
      expect(html.at_css(".ss-span[data-tone=danger] .ss-span-flags").text).to include("Aberta")
      expect(html.css(".ss-span-flags").text).to include("Sem leitura")

      get "/api/v1/dashboards/#{dashboard.id}", headers: auth_headers(user)
      expect(data["views"][0]["hero_now"]["title"]).to include("Ana")
    end
  end

  describe "lista dos pontos de um número (ideia 14)" do
    it "mostra os pontos com o motivo; item ou widget sem lista dá 404" do
      login
      get "/paineis/#{dashboard.id}/w/ac/pontos", params: { item: "offline" }
      expect(response).to have_http_status(:ok)
      html = Nokogiri::HTML(response.body)
      expect(html.css("#pontos-do-numero tbody tr").size).to eq(1)
      expect(html.text).to include("Fita").and include("Sem sinal")
      get "/paineis/#{dashboard.id}/w/b-on/pontos"
      expect(Nokogiri::HTML(response.body).text).to include("Teto").and include("Abajur")
      get "/paineis/#{dashboard.id}/w/ac/pontos", params: { item: "nada" }
      expect(response).to have_http_status(:not_found)
      get "/paineis/#{dashboard.id}/w/t-temp/pontos"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "Configurações → Painéis → Padrões" do
    it "edita os itens e o limite do dado velho, e volta ao padrão" do
      login
      get "/configuracoes/paineis"
      expect(response.body).to include("/configuracoes/paineis/padroes/#{site.id}")
      get "/configuracoes/paineis/padroes/#{site.id}"
      expect(response).to have_http_status(:ok)
      patch "/configuracoes/paineis/padroes/#{site.id}", params: {
        facts: { "0" => { id: "on", label_key: "on", icon: "light-bulb", aggregate: "count", query: { capability: "onoff", state: "on" } },
                 "1" => { id: "", label: { other: "%{count} quentes" }, aggregate: "count", tone: "danger", query: { device_class: "temperature", above: "20" } },
                 "2" => { id: "x", query: {} },
                 "3" => { id: "off", query: { capability: "" }, query_text: "quality=unavailable,error capability=contact,gate" } },
        stale: { "0" => { key: "temperature", min: "30" }, "1" => { key: "", min: "" } }
      }
      expect(response).to redirect_to("/configuracoes/paineis/padroes/#{site.id}")
      saved = site.reload.settings["dashboard_defaults"]
      expect(saved["area_facts"].size).to eq(3)
      expect(saved["area_facts"].last["query"]).to eq("quality" => "unavailable,error", "capability" => "contact,gate")
      expect(saved["area_facts"][1]).to include("label" => { "other" => "%{count} quentes" }, "tone" => "danger", "query" => { "device_class" => "temperature", "above" => "20" })
      expect(saved["stale_after_min"]).to eq("temperature" => 30)
      expect(widget(resolve, "ac")["data"]["facts"].map { _1["text"] }).to eq([ "2 ligados", "1 quentes" ])
      get "/configuracoes/paineis/padroes/#{site.id}"
      expect(response.body).to include("quality=unavailable,error capability=contact,gate")
      patch "/configuracoes/paineis/padroes/#{site.id}", params: { facts: { "0" => { id: "z", query_text: "nada=1" } } }
      expect(flash[:alert]).to include("consulta")

      patch "/configuracoes/paineis/padroes/#{site.id}", params: { facts: { "0" => { id: "a", aggregate: "median", query: { capability: "onoff" } } } }
      expect(site.reload.settings.dig("dashboard_defaults", "area_facts")).to eq([ { "id" => "a", "query" => { "capability" => "onoff" } } ]) # conta desconhecida = count
      patch "/configuracoes/paineis/padroes/#{site.id}", params: { reset: "1" }
      expect(site.reload.settings).to eq({})
    end

    it "morador não entra" do
      morador = create(:user, tenant: tenant, role: "member").tap { |u| within(tenant) { create(:site_membership, site: site, user: u, role: "resident") } }
      post "/entrar", params: { email: morador.email, password: "12345678" }
      get "/configuracoes/paineis/padroes/#{site.id}"
      expect(response).not_to have_http_status(:ok)
    end
  end

  describe "editor" do
    it "grava estilo, limite e itens próprios pelo formulário, e o topo da visão" do
      login
      patch "/paineis/#{dashboard.id}/rascunho", params: {
        op: "update_widget", target: "ac", view_id: "home",
        widget: { type: "area_card", area: sala.id, own_facts: "1", stale_after_min: "45",
                  facts: { "0" => { id: "on", label: { one: "Uma", other: "%{count} acesas" }, aggregate: "count", query: { capability: "onoff", state: "on" } } } },
        style: { "0" => { point: porta.id, is: "true", tone: "warn", badge: "Porta", after: "22:00", before: "06:00" }, "1" => { tone: "" } }
      }
      w = dashboard.reload.draft["views"][0]["sections"][0]["widgets"][0]
      expect(w["facts"]).to eq([ { "id" => "on", "label" => { "one" => "Uma", "other" => "%{count} acesas" }, "query" => { "capability" => "onoff", "state" => "on" }, "aggregate" => "count" } ])
      expect(w["stale_after_min"]).to eq(45)
      expect(w["style_if"]).to eq([ { "when" => { "state" => { "point" => porta.id, "is" => true }, "time" => { "after" => "22:00", "before" => "06:00" } }, "tone" => "warn", "badge" => "Porta" } ])

      get "/paineis/#{dashboard.id}/editar", params: { view: "home", w: "ac" }
      expect(response).to have_http_status(:ok)

      patch "/paineis/#{dashboard.id}/rascunho", params: { op: "update_view", target: "home", view_id: "home", title: "Início",
                                                           hero: { present: "1", title: "Oi", kicker: "", greeting: "0", hide: "1" } }
      expect(dashboard.reload.draft["views"][0]["hero"]).to eq("title" => "Oi", "greeting" => false, "hide" => true)
      patch "/paineis/#{dashboard.id}/rascunho", params: { op: "update_view", target: "home", view_id: "home", title: "Início", hero: { present: "1" } }
      expect(dashboard.reload.draft["views"][0]).not_to have_key("hero")
    end
  end
end
