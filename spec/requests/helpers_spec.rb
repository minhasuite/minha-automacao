require "rails_helper"

RSpec.describe "Helpers do local (F8e)" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })
  def helpers = within(tenant) { site.points.helpers.order(:created_at).to_a }
  def data = response.parsed_body["data"]

  def create_helper(tipo, form)
    post "/locais/#{site.id}/helpers", params: { tipo: tipo, helper: form }
    helpers.last
  end

  describe "web" do
    before { sign_in }

    it "lista vazia, catálogo com todos os tipos e o formulário de cada um" do
      get "/locais/#{site.id}/helpers"
      expect(response.body).to include("Nenhum helper neste local", "Criar helper")
      get "/locais/#{site.id}/helpers/novo"
      expect(response.body).to include("Liga/desliga", "Lista de opções", "Temporizador", "Sensor calculado", "Estatística")
      HelperTypes.plugins.each do |p|
        get "/locais/#{site.id}/helpers/novo", params: { tipo: p.key }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Novo helper: #{p.title}")
        # Tipo sem partial própria e com form_spec: o formulário genérico, campo a campo.
        p.form_spec.each { |name, *| expect(response.body).to include("helper[#{name}]") }
      end
    end

    it "cria, muda o valor na lista, filtra, edita e exclui mostrando onde é usado" do
      mode = create_helper("select", { name: "Modo da casa", icon: "home", options_text: "Casa, Fora, Noite", restore: "1" })
      expect(response).to redirect_to("/locais/#{site.id}/helpers")
      expect(mode).to have_attributes(helper: "select", value: "Casa", icon: "home")
      counter = create_helper("counter", { name: "Visitas", initial: "0", step: "1" })
      create_helper("toggle", { name: "Férias", initial: "0" })

      post "/locais/#{site.id}/helpers", params: { tipo: "counter", helper: { name: "Ruim", initial: "5", max: "2" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("valor inicial precisa estar entre")
      post "/locais/#{site.id}/helpers", params: { tipo: "nada", helper: { name: "x" } }
      expect(response).to redirect_to("/locais/#{site.id}/helpers/novo")

      get "/locais/#{site.id}/helpers"
      expect(response.body).to include("Modo da casa", "Visitas", "Férias", "ss-switch", "Mais Visitas", "turbo-cable-stream-source")
      get "/locais/#{site.id}/helpers", params: { tipo: "counter" }
      expect(response.body).to include("Visitas")
      expect(response.body).not_to include("Modo da casa")
      get "/locais/#{site.id}/helpers", params: { q: "modo" }
      expect(response.body).to include("Modo da casa")
      expect(response.body).not_to include("Férias")
      get "/locais/#{site.id}/helpers", params: { q: "zzz" }
      expect(response.body).to include("com esses filtros")

      post "/pontos/#{counter.id}/comando", params: { command: "increment" }, headers: { "Referer" => "/locais/#{site.id}/helpers" }
      expect(response).to redirect_to("/locais/#{site.id}/helpers")
      expect(within(tenant) { counter.reload.value }).to eq(1)

      within(tenant) do
        a = site.automations.create!(name: "Usa o modo", definition: { "triggers" => [ { "type" => "state", "point" => mode.id } ], "actions" => [] })
        expect(a).to be_persisted
      end
      get "/helpers/#{mode.id}/editar"
      expect(response.body).to include("Onde é usado", "Usa o modo", "Ele é usado em 1 lugar(es)")
      patch "/helpers/#{mode.id}", params: { helper: { name: "Modo", options_text: "Casa, Fora" } }
      expect(within(tenant) { mode.reload.option_values }).to eq(%w[Casa Fora])
      patch "/helpers/#{mode.id}", params: { helper: { name: "", options_text: "" } }
      expect(response).to have_http_status(:unprocessable_content)
      delete "/helpers/#{mode.id}"
      expect(response).to redirect_to("/locais/#{site.id}/helpers")
      expect(helpers.map(&:name)).to eq(%w[Visitas Férias])

      get "/locais/#{site.id}/dispositivos"
      expect(response.body).not_to include("/dispositivos/#{within(tenant) { counter.device_id }}")
    end

    it "papel: hóspede vê e comanda (risco normal), mas não cadastra" do
      t = create_helper("toggle", { name: "Visita" })
      guest = create(:user, tenant: tenant, role: "member").tap { |u| within(tenant) { create(:site_membership, site: site, user: u, role: "guest") } }
      sign_in(guest)
      get "/locais/#{site.id}/helpers"
      expect(response.body).to include("Visita", "ss-switch")
      expect(response.body).not_to include("Criar helper")
      get "/locais/#{site.id}/helpers/novo"
      expect(response).to have_http_status(:forbidden).or have_http_status(:redirect)
      get "/helpers/#{t.id}/editar"
      expect(response).not_to have_http_status(:ok)
    end

    it "editor de automação lista as ações do plugin e os estados do temporizador" do
      timer = create_helper("timer", { name: "Rega", duration: "20m" })
      a = within(tenant) do
        site.automations.create!(name: "Fim da rega", draft: { "triggers" => [ { "type" => "state", "point" => timer.id, "to" => "finished" } ],
                                                               "conditions" => [], "actions" => [ { "type" => "command", "point" => timer.id, "command" => "start" } ] })
      end
      get "/automacoes/#{a.id}/editar", params: { b: "actions.0" }
      expect(response.body).to include("Iniciar temporizador", "Cancelar temporizador")
      get "/automacoes/#{a.id}/editar", params: { b: "triggers.0" }
      expect(response.body).to include("Terminou")
    end

    it "painel com widgets de helper: liga/desliga, número em caixa, texto, data, contador e temporizador" do
      ids = {
        t: create_helper("toggle", { name: "Férias" }), n: create_helper("number", { name: "Alvo", min: "0", max: "50", step: "1", mode: "box" }),
        x: create_helper("text", { name: "Recado" }), d: create_helper("datetime", { name: "Acordar", mode: "time" }),
        c: create_helper("counter", { name: "Ciclos" }), r: create_helper("timer", { name: "Rega", duration: "5m" }),
        b: create_helper("button", { name: "Campainha" })
      }.transform_values(&:id)
      widgets = ids.map { |k, id| { "id" => "w#{k}", "type" => "tile", "bind" => id } }
      definition = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "Helpers", "sections" => [ { "id" => "s", "widgets" => widgets } ] } ] }
      d = within(tenant) { site.dashboards.create!(name: "Helpers", kind: "custom", definition: definition, version: 1) }
      get "/paineis/#{d.id}"
      expect(response.body).to include("Férias", 'type="number"', 'type="text"', 'type="time"', "Mais", "Iniciar", "Acionar Campainha")
      post "/pontos/#{ids[:r]}/comando", params: { command: "start", dashboard_id: d.id, widget_id: "wr" }, headers: { "Turbo-Frame" => "w_wr" }
      get "/paineis/#{d.id}/w/wr"
      expect(response.body).to include("Contando, termina às", "Pausar")
    end
  end

  describe "API" do
    let(:owner) { user }

    it "lista os helpers (com chave de leitura) e escreve o valor validando pelo tipo" do
      sign_in
      counter = create_helper("counter", { name: "Ciclos", initial: "0", max: "10" })
      create_helper("toggle", { name: "Férias" })
      key = ->(scopes) { { "X-Api-Key" => within(tenant) { ServiceApiKey.issue(owner, name: "k", scopes: scopes, site_ids: [ site.id ]).last } } }

      get "/api/v1/sites/#{site.id}/helpers", headers: key.call(%w[read])
      expect(data.map { |p| [ p["name"], p["helper"] ] }).to contain_exactly([ "Ciclos", "counter" ], [ "Férias", "toggle" ])
      expect(response.parsed_body.dig("meta", "types").size).to eq(HelperTypes.keys.size)
      get "/api/v1/sites/#{site.id}/helpers", params: { type: "toggle" }, headers: key.call(%w[read])
      expect(data.map { |p| p["name"] }).to eq([ "Férias" ])

      w = key.call(%w[write])
      post "/api/v1/points/#{counter.id}/value", params: { value: "7" }, headers: w
      expect(data["value"]).to eq(7)
      post "/api/v1/points/#{counter.id}/value", params: { value: "abc" }, headers: w
      expect(response).to have_http_status(:unprocessable_content)
      post "/api/v1/points/#{counter.id}/commands", params: { command: "increment" }, headers: key.call(%w[command])
      expect(response).to have_http_status(:accepted)
      expect(within(tenant) { counter.reload.value }).to eq(8)
    end
  end
end
