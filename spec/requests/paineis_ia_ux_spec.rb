require "rails_helper"

# paineis-ia: Histórico mais útil (sugestões, Hoje/Ontem, resumo da janela), Mapa com o passo do
# celular e a pessoa ligada sozinha ao celular, e o Uso de IA sem texto saindo do card.
RSpec.describe "Painéis IA, Histórico e Mapa (paineis-ia)" do
  let(:user) { create(:user, name: "Teste Ana") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa Teste", latitude: -15.8, longitude: -47.9, timezone: "America/Sao_Paulo") } }
  let!(:sala) { within(tenant) { create(:area, site: site, name: "Sala") } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  def sensor(name)
    within(tenant) do
      d = create(:device, site: site, area: sala, name: name)
      [ create(:point, device: d, site: site, name: "Temperatura", capability: "measure", data_type: "decimal", unit: "°C", device_class: "temperature"),
        create(:point, device: d, site: site, name: "Porta", capability: "contact") ]
    end
  end

  before { sign_in }

  describe "Histórico" do
    it "sem pontos: sugestões prontas (mesma unidade e classe; portas juntas) e os atalhos Hoje/Ontem" do
      a = sensor("Teste Sensor A")
      b = sensor("Teste Sensor B")
      get "/historico"
      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include("Escolha os pontos para comparar.", "Temperatura · °C", "Hoje", "Ontem", "Escolher pontos")
      temps = within(tenant) { Points::Overlay.suggestions(site) }.find { |g| g[:unit] == "°C" }
      expect(temps[:ids]).to contain_exactly(a.first.id, b.first.id)
      expect(within(tenant) { Points::Overlay.suggestions(site) }.find { |g| g[:label] == "Porta" }[:count]).to eq(2)
      expect(body).to include(%(data-ss-filter-text="Temperatura Teste Sensor A Sala"))
    end

    it "com pontos: resumo da janela (mín., máx., média), lista dos escolhidos e limpar" do
      t = sensor("Teste Sensor A").first
      within(tenant) do
        travel_to(3.hours.ago) { t.report!(20.0) }
        travel_to(2.hours.ago) { t.report!(30.0) }
      end
      get "/historico", params: { point_ids: [ t.id ], range: "6h" }
      expect(response.body).to include("mín. 20", "máx. 30", "1 de 12 ponto", "Limpar", 'data-controller="ss-time-chart')
    end

    it "Hoje = do começo do dia até agora; Ontem = o dia inteiro; o chip marcado bate com a janela" do
      now = Time.zone.parse("2026-11-14 15:30")
      from, to = Points::Overlay.window({ range: "today" }, now: now)
      expect([ from, to ]).to eq([ now.beginning_of_day, now ])
      from, to = Points::Overlay.window({ range: "yesterday" }, now: now)
      expect([ from, to ]).to eq([ (now - 1.day).beginning_of_day, now.beginning_of_day ])
      expect(Points::Overlay.current?("yesterday", from, to, now: now)).to be(true)
      expect(Points::Overlay.current?("24h", now - 24.hours, now, now: now)).to be(true)
      expect(Points::Overlay.current?("today", from, to, now: now)).to be(false)
    end
  end

  describe "Mapa: o celular do dono" do
    it "sem celular registrado mostra o passo no app; registrado sem localização, o outro passo; com localização, some" do
      get "/mapa"
      expect(response.body).to include("Seu celular não aparece?", "Sensores do celular")
      phone = within(tenant) { Integrations::MobileAppPlugin.register!(site, user, install_id: "teste12345", name: "Celular Teste") }
      expect(within(tenant) { Maps.data(site, user: user) }["phone"]["state"]).to eq("no_location")
      within(tenant) { Integrations::MobileAppPlugin.report!(phone, "battery" => 80) }
      expect(within(tenant) { Maps.data(site, user: user) }["phone"]["state"]).to eq("no_location")
      within(tenant) { Integrations::MobileAppPlugin.report!(phone, "location" => { "latitude" => -15.8, "longitude" => -47.9 }) }
      get "/mapa"
      expect(response.body).not_to include("Seu celular não aparece?")
      get "/api/v1/sites/#{site.id}/map", headers: auth_headers(user)
      expect(response.parsed_body.dig("data", "phone")).to be_nil
    end

    it "a primeira localização liga o celular à pessoa do dono (cria; depois só acrescenta a fonte, sem duplicar)" do
      phone = within(tenant) { Integrations::MobileAppPlugin.register!(site, user, install_id: "teste12345", name: "Celular Teste") }
      within(tenant) { 2.times { Integrations::MobileAppPlugin.report!(phone, "location" => { "latitude" => -15.8, "longitude" => -47.9 }) } }
      people = within(tenant) { People.persons(site).to_a }
      expect(people.map(&:name)).to eq([ "Teste" ]) # como no assistente da tela Pessoas (primeiro nome)
      gps = within(tenant) { phone.points.find_by!(device_class: "location") }
      expect(people.first.address).to include("user_id" => user.id, "sources" => [ gps.id ], "auto" => true)
      expect(within(tenant) { Maps.data(site, user: user) }["people"].first).to include("name" => "Teste", "precise" => true)

      other = within(tenant) { Integrations::MobileAppPlugin.register!(site, user, install_id: "outro12345", name: "Tablet Teste") }
      within(tenant) { Integrations::MobileAppPlugin.report!(other, "location" => { "latitude" => -15.8, "longitude" => -47.9 }) }
      expect(within(tenant) { People.persons(site).map { |p| p.address["sources"].size } }).to eq([ 2 ])

      # Criada à mão para o mesmo usuário, a automática sai (uma pessoa por usuário).
      within(tenant) { HelperTypes.save(HelperTypes.build(site, HelperTypes::Person), "name" => "Ana", "user_id" => user.id, "sources" => [ gps.id ]) }
      expect(within(tenant) { People.persons(site).map(&:name) }).to eq([ "Ana" ])
    end

    it "na API, o mesmo passo vem no `phone` do mapa" do
      get "/api/v1/sites/#{site.id}/map", headers: auth_headers(user)
      expect(response.parsed_body.dig("data", "phone")).to include("state" => "none", "title" => "Seu celular não aparece?")
    end
  end

  it "Uso de IA: a lista por automação não estoura o card (coluna minmax(0,1fr) e nome que quebra)" do
    auto = within(tenant) { Automation.create!(site: site, name: "Área Gourmet | IA | Câmera vê quem chegou com um nome bem comprido", kind: "automation", mode: "single") }
    within(tenant) do
      AiCall.create!(site: site, automation: auto, source: "automacao", provider: "anthropic", model: "claude-haiku-5-5", status: "ok", input_tokens: 10, output_tokens: 5)
      AiCall.create!(site: site, automation: auto, source: "automacao", provider: "anthropic", model: "claude-haiku-5-5", status: "error", attempts: 3,
                     error: "A IA não conseguiu responder agora. Tente de novo.", detail: "HTTP 529 overloaded_error")
      defn = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "IA", "type" => "sections", "sections" => [ { "id" => "s", "widgets" => [
        { "id" => "u", "type" => "ai_usage" }, { "id" => "l", "type" => "ai_log" } ] } ] } ] }
      site.dashboards.create!(name: "IA", kind: "custom", auto: false, definition: defn).tap { |d| d.publish!(defn) }
    end
    get "/paineis/#{within(tenant) { site.dashboards.find_by!(name: 'IA') }.id}"
    expect(response.body).to include("grid grid-cols-1 gap-0.5", "whitespace-normal", "3 tentativas", "HTTP 529 overloaded_error")
  end
end
