require "rails_helper"

RSpec::Matchers.define_negated_matcher :exclude, :include

# Diário e Histórico da instalação (paridade com o Logbook e o History do HA):
# fontes por registro (uma falsa entra por stub_const), filtros, cursor,
# papéis, CSV e a mesma coisa na API.
RSpec.describe "Diário e Histórico" do
  let(:user) { create(:user, name: "Herlon Teste") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa Teste") } }
  let!(:area) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let!(:device) { within(tenant) { create(:device, site: site, area: area, name: "Interruptor da sala") } }
  let!(:luz) { within(tenant) { create(:point, device: device, name: "Luz do teto", key: "sala.luz", capability: "onoff", writable: true) } }
  let!(:power) { within(tenant) { create(:point, device: device, name: "Potência", key: "sala.potencia", capability: "measure", data_type: "decimal", unit: "W") } }
  let!(:porta) do
    within(tenant) { create(:point, device: create(:device, site: site, name: "Porta"), name: "Porta da frente", key: "porta.contato", capability: "contact") }
  end

  def seed!
    within(tenant) do
      travel_to(3.hours.ago) { luz.report!(true) }
      travel_to(2.hours.ago) { luz.report!(false) }
      travel_to(90.minutes.ago) { power.report!(120.5) }
      travel_to(80.minutes.ago) { power.report!(300.0) }
      travel_to(70.minutes.ago) { porta.report!(true, quality: "unavailable") }
      Command.create!(site: site, point: luz, user: user, command: "on", source: "web", status: "confirmed", created_at: 50.minutes.ago)
      auto = Automation.create!(site: site, name: "Teste chegada")
      AutomationRun.create!(automation: auto, site: site, status: "done", started_at: 40.minutes.ago)
      Scene.create!(site: site, name: "Teste cinema", items: [ { point_id: luz.id, command: "on" } ]).activate!(source: "web", user: user)
      AlertRule.create!(point: porta, name: "Teste porta aberta", value: true) # abre o alerta (a porta está aberta)
    end
  end

  before { post("/entrar", params: { email: user.email, password: "12345678" }) }

  it "junta mudanças, comandos, execuções, cenas, alertas, conexão, cadastro e entradas" do
    seed!
    get "/diario"
    expect(response).to have_http_status(:ok)
    body = response.body
    expect(body).to include("Luz do teto", "Ligado", "Desligado", "Teste chegada", "Teste cinema", "Teste porta aberta", "Porta da frente",
                            "Indisponível", "por Herlon Teste", "Entrou", "Criado")
    expect(body).not_to include("120,5") # número fica para o Histórico, como no HA
    expect(body).to include(%(href="/historico?site_id=#{site.id}"))
  end

  it "filtra por área, ponto, pessoa, tipo e busca" do
    seed!
    get "/diario", params: { area_id: area.id }
    expect(response.body).to include("Luz do teto").and(exclude("Teste porta aberta", "Indisponível", "Teste chegada"))
    get "/diario", params: { user_id: user.id }
    expect(response.body).to include("Teste cinema", "Ligar").and(exclude("Desligado", "Indisponível"))
    get "/diario", params: { sources: %w[runs] }
    expect(response.body).to include("Teste chegada").and(exclude("Teste cinema"))
    get "/diario", params: { q: "cinema" }
    expect(response.body).to include("Teste cinema").and(exclude("Interruptor da sala</a>"))
  end

  it "pagina por cursor num turbo-frame preguiçoso" do
    seed!
    stub_const("Logbook::PAGE", 3)
    get "/diario"
    src = response.body[%r{src="(/diario\?[^"]+)"}, 1]
    expect(src).to include("before=")
    get CGI.unescapeHTML(src), headers: { "Turbo-Frame" => "lb-x" }
    expect(response.body).to include("<turbo-frame", "lb-item")
  end

  it "visitante não vê cadastro nem entradas" do
    guest = create(:user, tenant: tenant, role: "member")
    within(tenant) { SiteMembership.create!(site: site, user: guest, role: "guest") }
    seed!
    post("/entrar", params: { email: guest.email, password: "12345678" })
    get "/diario"
    expect(response.body).to include("Luz do teto").and(exclude("Entrou", "Criado"))
  end

  it "fonte nova por registro (stub_const) entra na tela e na API sem mudar o núcleo" do
    fake = Class.new(Logbook::Sources::Base) do
      describe key: "falsa", label: "Fonte falsa", icon: "star"
      def self.fetch(f) = [ item(at: 5.minutes.ago, title: "Teste da fonte falsa", state: "Ok", tone: "success", detail: f.site.name) ]
    end
    stub_const("Logbook::Sources::Falsa", fake)
    stub_const("Logbook::SOURCES", Logbook::SOURCES + %w[Falsa])
    get "/diario"
    expect(response.body).to include("Teste da fonte falsa", "Fonte falsa")
    get "/api/v1/sites/#{site.id}/logbook", headers: auth_headers(user), params: { sources: %w[falsa] }
    expect(data.pluck("title")).to eq([ "Teste da fonte falsa" ])
    expect(json["meta"]["sources"].pluck("key")).to include("falsa")
  end

  it "API do diário com cursor" do
    seed!
    get "/api/v1/sites/#{site.id}/logbook", headers: auth_headers(user), params: { limit: 2 }
    expect(data.size).to eq(2)
    expect(data.first.keys).to include("at", "source", "title", "state")
    cursor = json["meta"]["next_before"]
    get "/api/v1/sites/#{site.id}/logbook", headers: auth_headers(user), params: { limit: 2, before: cursor }
    expect(data.pluck("at").max).to be < cursor
  end

  it "histórico sobrepõe pontos (linha e faixas), dá zoom e exporta CSV; a API traz as séries" do
    seed!
    get "/historico", params: { point_ids: [ power.id, luz.id ], range: "6h" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("hx-plot", "<polyline", "Linha do tempo", "hx-band-svg", "Ligado ·", "Aproximar", "Exportar CSV")

    get "/historico.csv", params: { point_ids: [ power.id, luz.id ], range: "6h" }
    expect(response.media_type).to eq("text/csv")
    csv = response.body
    expect(csv.lines.first).to start_with("ponto;chave;unidade")
    expect(csv).to include("Potência;sala.potencia;W", "120,5", "Luz do teto;sala.luz;;", "Ligado", "Desligado")

    get "/api/v1/sites/#{site.id}/history", headers: auth_headers(user), params: { point_ids: [ power.id, luz.id ], range: "6h" }
    line, bands = data
    expect(line).to include("kind" => "line", "unit" => "W", "resolution" => "raw")
    expect(line["items"].pluck("avg")).to include(120.5, 300.0)
    expect(bands["kind"]).to eq("bands")
    expect(bands["items"].pluck("text").first(2)).to eq(%w[Ligado Desligado])

    get "/api/v1/sites/#{site.id}/history", headers: auth_headers(user)
    expect(response).to have_http_status(:bad_request)
  end

  it "janela do histórico: atalho, datas, limites" do
    now = Time.zone.parse("2026-11-01 12:00")
    expect(Points::Overlay.window({ range: "1h" }, now: now)).to eq([ now - 1.hour, now ])
    from, to = Points::Overlay.window({ from: "2026-10-31T10:00", to: "2026-10-31T09:00" }, now: now)
    expect(to - from).to eq(24.hours)
    from, to = Points::Overlay.window({ from: "2026-10-31T10:00", to: "2026-10-31T10:01" }, now: now)
    expect(to - from).to eq(5.minutes)
    expect(Points::Overlay.window({ to: "2030-01-01" }, now: now).last).to eq(now)
  end
end
