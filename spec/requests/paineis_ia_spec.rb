require "rails_helper"

# Revisão dos painéis importados do HA: a view IA (o pacote `sensor.ia_historico`) vira os widgets daqui
# (Uso de IA, Linha do tempo da IA, Perguntar à casa), o tile que roda a automação mostra quando rodou,
# selo sem valor some e a agenda sem par fica (com todas as agendas e o "ligar uma agenda"). Nada chama
# IA de verdade.
RSpec.describe "Painéis: IA, rodar automação, selos e agenda" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa IA") } }
  let(:src) { "home_assistant" }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  def translate(sections, refs = Integrations::HaDashboards.refs_for(site, {}))
    config = { "views" => [ { "path" => "ia", "title" => "IA", "badges" => [ { "type" => "entity", "entity" => "sensor.ia_historico" } ],
                              "sections" => sections } ] }
    Dashboards::HaImport.new(config, refs: refs, url_path: "ia", image: ->(_) { }, theme: nil).call
  end

  def publish(defn) = within(tenant) { site.dashboards.create!(name: "IA", kind: "custom", auto: false, definition: defn).tap { |d| d.publish!(defn) } }

  def automation(name)
    within(tenant) do
      Automation.create!(site: site, name: name, kind: "automation", mode: "single").tap do |a|
        a.publish!({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "trace_note", "message" => "rodou" } ] })
        a.update!(enabled: true)
      end
    end
  end

  it "o pacote de IA do HA vira Uso de IA, Linha do tempo e Perguntar à casa; a fila de avaliação sai" do
    hist = ->(attr, name) { { "type" => "tile", "entity" => "sensor.ia_historico", "name" => name, "state_content" => attr } }
    pend = [ { "condition" => "numeric_state", "entity" => "sensor.ia_historico", "attribute" => "sem_retorno", "above" => 0 } ]
    sections = [
      { "type" => "grid", "cards" => [
        { "type" => "heading", "heading" => "Pergunte à IA" },
        { "type" => "custom:casa-campo-texto", "entity" => "input_text.ia_pergunta", "name" => "Claude", "acao" => "script.ia_perguntar",
          "placeholder" => "Ex.: alguma porta aberta?" },
        { "type" => "markdown", "content" => "**{{ state_attr('sensor.ia_pergunta', 'pergunta') }}**",
          "visibility" => [ { "condition" => "state", "entity" => "sensor.ia_pergunta", "state_not" => "unknown" } ] } ] },
      { "type" => "grid", "cards" => [
        { "type" => "heading", "heading" => "Para avaliar" },
        { "type" => "markdown", "content" => "{% from 'ia_historico.jinja' import pendente %}{{ pendente() }}", "visibility" => pend },
        { "type" => "tile", "entity" => "script.ia_avaliar", "name" => "Correto", "visibility" => pend } ] },
      { "type" => "grid", "cards" => [
        { "type" => "heading", "heading" => "Últimos 30 dias" },
        hist.("acerto_vigia", "Vigia"), hist.("falhas_30d", "Falhas da IA"), hist.("gasto_mes", "Gasto"),
        { "type" => "heading", "heading" => "Linha do tempo" },
        { "type" => "markdown", "content" => "{% from 'ia_historico.jinja' import linha_do_tempo %}{{ linha_do_tempo() }}" } ] },
      { "type" => "grid", "cards" => [ { "type" => "heading", "heading" => "Só título" } ] }
    ]
    result = within(tenant) { translate(sections) }
    view = result.definition.dig("views", 0)
    expect(view["badges"]).to be_blank # os números da IA estão no card
    ask, usage, only_title = view["sections"]
    expect(view["sections"].size).to eq(3) # "Para avaliar" saiu inteira; a seção só com título (do HA) fica
    expect(ask["widgets"].map { _1["type"] }).to eq(%w[heading ask])
    expect(ask["widgets"].last).to include("label" => "Claude", "placeholder" => "Ex.: alguma porta aberta?")
    expect(usage["widgets"].map { _1["type"] }).to eq(%w[heading ai_usage heading ai_log])
    expect(only_title["widgets"].map { _1["title"] }).to eq([ "Só título" ])
    expect(result.notes.join).to include("fila de avaliação")
    expect(Dashboards::Schema.errors(result.definition)).to be_empty

    # Dados: chamadas de hoje, do mês, falhas e gasto (só para quem administra), por automação e a linha do tempo.
    vigia = automation("Vigia de anomalia")
    within(tenant) do
      AiCall.create!(site: site, automation: vigia, source: "automacao", provider: "anthropic", model: "claude-haiku-5-5",
                     input_tokens: 1000, output_tokens: 100, cost: 0.01, status: "ok")
      AiCall.create!(site: site, automation: vigia, source: "automacao", provider: "anthropic", model: "claude-haiku-5-5",
                     cost: 0, status: "error", error: "Tempo esgotado")
      AiCall.create!(site: site, source: "pergunta", provider: "anthropic", model: "claude-haiku-5-5", cost: 0.002, status: "ok")
    end
    dash = publish(result.definition)
    resolved = within(tenant) { Dashboards::Resolver.new(dash, role: "owner").call }
    widgets = resolved["views"].flat_map { |v| v["sections"].flat_map { _1["widgets"] } }.index_by { _1["type"] }
    numbers = widgets["ai_usage"]["data"]["items"].to_h { [ _1["key"], _1["value"] ] }
    expect(numbers).to include("today" => 3, "month" => 3, "errors" => 1, "cost" => 0.012)
    expect(widgets["ai_usage"]["data"]["by_automation"].first).to include("name" => "Vigia de anomalia", "calls" => 2, "errors" => 1)
    log = widgets["ai_log"]["data"]["items"]
    expect(log.map { _1["title"] }).to include("Vigia de anomalia", "Perguntar à casa")
    expect(log.find { _1["tone"] == "danger" }["detail"]).to include("Tempo esgotado")
    resident = within(tenant) { Dashboards::Resolver.new(dash, role: "resident").call }
    items = resident["views"][0]["sections"].flat_map { _1["widgets"] }.find { _1["type"] == "ai_usage" }["data"]["items"]
    expect(items.map { _1["key"] }).not_to include("cost") # gasto só para quem administra

    # A tela: o card de perguntar sem provedor leva às configurações; os cards de uso e linha do tempo aparecem.
    sign_in
    get "/paineis/#{dash.id}"
    expect(response.body).to include("Ligue um provedor de IA", "Vigia de anomalia", "Tempo esgotado", "Gasto no mês")
  end

  it "Perguntar à casa responde no card (web) e pela API (app)" do
    allow(Ai::Ask).to receive(:response).and_return(
      Ai::Request::Response.new(data: "A porta da cozinha está aberta.", provider: "anthropic", model: "claude-haiku-5-5", input_tokens: 10, output_tokens: 5, cost: 0)
    )
    sign_in
    post "/perguntar/painel", params: { site_id: site.id, frame: "ask_w-1", question: "Alguma porta aberta?" }
    expect(response.body).to include('id="ask_w-1"', "A porta da cozinha está aberta.", "Alguma porta aberta?")
    post "/perguntar/painel", params: { site_id: site.id, frame: "<script>", question: "x" }
    expect(response).to have_http_status(:bad_request)

    post "/api/v1/sites/#{site.id}/ask", params: { question: "Alguma porta aberta?" }, headers: auth_headers(user)
    expect(response.parsed_body.dig("data", "answer")).to eq("A porta da cozinha está aberta.")
    post "/api/v1/sites/#{site.id}/ask", params: { question: " " }, headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "tile que roda a automação: o ponto aceita run (dispara agora) e o tile mostra quando rodou" do
    vigia = automation("Vigia")
    point = within(tenant) { AutomationPoints.sync!(vigia).tap { |p| ExternalRef.link!(site, src, "automation.vigia", kind: "entity", target: p) } }
    within(tenant) { ExternalRef.link!(site, src, "automation.vigia", kind: "automation", target: vigia) }
    expect(Points::Command.commands_for(point)).to include("run", "toggle")
    tile = { "type" => "tile", "entity" => "automation.vigia", "name" => "Vigia", "state_content" => "last_triggered", "grid_options" => { "columns" => 4 },
             "tap_action" => { "action" => "perform-action", "perform_action" => "automation.trigger", "target" => { "entity_id" => "automation.vigia" },
                               "confirmation" => { "text" => "Rodar o Vigia agora?" } } }
    defn = within(tenant) { translate([ { "type" => "grid", "cards" => [ tile ] } ]).definition }
    dash = publish(defn)
    sign_in
    get "/paineis/#{dash.id}"
    expect(response.body).to include("Ainda não rodou", "Rodar o Vigia agora?")
    expect(response.body).not_to include("ss-switch") # nada de interruptor "Desligado" no lugar do rodar

    expect { within(tenant) { Points::Command.call(point, "run", source: "web", user: user) } }.to change { within(tenant) { vigia.runs.count } }.by(1)
    within(tenant) { vigia.update_columns(last_run_at: 5.minutes.ago) }
    get "/paineis/#{dash.id}"
    expect(response.body).to include("Rodou há 5 min")
  end

  it "selo sem valor some; agenda sem par fica, com todas as agendas e o ligar uma agenda" do
    dev = within(tenant) { create(:device, site: site, name: "Resumo", driver: "virtual") }
    within(tenant) do
      create(:point, site: site, device: dev, key: "resumo", name: "Resumo", capability: "measure", value: 3)
                    .tap { |p| ExternalRef.link!(site, src, "sensor.resumo", kind: "entity", target: p) }
    end
    config = { "views" => [ { "path" => "casa", "title" => "Casa",
                              "badges" => [ { "type" => "entity", "entity" => "sensor.resumo", "state_content" => "nao_existe", "name" => "Atualizações" } ],
                              "sections" => [ { "type" => "grid", "cards" => [ { "type" => "custom:atomic-calendar-revive", "entities" => [ "calendar.familia" ] } ] } ] } ] }
    result = within(tenant) { Dashboards::HaImport.new(config, refs: Integrations::HaDashboards.refs_for(site, {}), url_path: "casa", image: ->(_) { }, theme: nil).call }
    cal = result.definition.dig("views", 0, "sections", 0, "widgets", 0)
    expect(cal).to include("type" => "calendar")
    expect(cal).not_to have_key("binds")
    dash = publish(result.definition)
    sign_in
    get "/paineis/#{dash.id}"
    expect(response.body).not_to include("Atualizações") # atributo que não veio: o selo não mostra "—"
    expect(response.body).to include("Nenhuma agenda ligada ainda", "Ligar uma agenda", "tipo=calendar")
  end
end
