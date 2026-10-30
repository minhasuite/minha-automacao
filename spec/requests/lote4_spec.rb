require "rails_helper"

# Lote 4: telas da integração Clima, do editor de painel (widget Clima, Texto
# com Liquid, "Mostrar em") e da ação "Ler previsão do tempo".
RSpec.describe "Lote 4: telas de clima e painel" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa", latitude: -10.5, longitude: -40.25) } }
  let!(:lamp) { within(tenant) { create(:point, device: create(:device, site: site, name: "Sala"), name: "Luz", key: "sala.luz", value: true) } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  before do
    sign_in
    stub_request(:get, %r{\Ahttps://api\.open-meteo\.com/v1/forecast\?}).to_return(body: {
      "current" => { "time" => "2026-10-30T12:00", "temperature_2m" => 21.3, "relative_humidity_2m" => 80, "weather_code" => 63, "is_day" => 1 },
      "daily" => { "time" => [ Date.current.iso8601, (Date.current + 1).iso8601 ], "weather_code" => [ 63, 0 ],
                   "temperature_2m_max" => [ 24, 29 ], "temperature_2m_min" => [ 17, 18 ], "precipitation_probability_max" => [ 90, 0 ] },
      "hourly" => { "time" => [], "temperature_2m" => [], "weather_code" => [] }
    }.to_json)
  end

  def weather_point = within(tenant) { site.points.find_by!(capability: "weather") }

  it "Clima: formulário, conexão pela localização do local e Reconfigurar com localização própria" do
    get "/locais/#{site.id}/integracoes/nova", params: { tipo: "weather" }
    expect(response.body).to include("Provedor", "Open-Meteo (grátis, sem chave)", "Localização", "vazio = a do local: -10.5, -40.25")
    post "/locais/#{site.id}/integracoes", params: { tipo: "weather", integration: { name: "Tempo", provider: "open_meteo", latitude: "", longitude: "" } }
    expect(response).to redirect_to("/locais/#{site.id}/integracoes")
    expect(flash[:notice]).to eq("Clima conectado: chuva.")
    integration = within(tenant) { Integration.find_by!(driver: "weather") }

    get "/locais/#{site.id}/integracoes"
    expect(response.body).to include("Tempo", "Open-Meteo")
    get "/integracoes/#{integration.id}/conectar"
    expect(response.body).to include("Latitude", "Longitude")
    post "/integracoes/#{integration.id}/conectar", params: { integration: { provider: "open_meteo", latitude: "-3,5", longitude: "-60" } }
    expect(within(tenant) { integration.reload.settings }).to include("latitude" => -3.5, "longitude" => -60.0)
    expect(a_request(:get, /latitude=-3.5&longitude=-60.0/)).to have_been_made

    get "/pontos/#{weather_point.id}"
    expect(response.body).to include("Chuva")
  end

  it "editor do painel: widget Clima e Texto com Liquid, Mostrar em, e o visible_if do JSON fica ao editar" do
    post "/locais/#{site.id}/integracoes", params: { tipo: "weather", integration: { provider: "open_meteo" } }
    d = within(tenant) { Dashboard.ensure_for(site).first }
    get "/paineis/#{d.id}/editar"
    expect(response.body).to include(%(<option value="weather">Clima</option>), ".dw-wf:has(option[value=weather]:checked) [data-for~=weather]", "Mostrar em")
    patch "/paineis/#{d.id}/rascunho", params: { op: "add_view", title: "Tempo" }
    v = within(tenant) { d.reload.draft["views"].last["id"] }
    patch "/paineis/#{d.id}/rascunho", params: { op: "add_section", view_id: v, title: "Tempo" }
    s = within(tenant) { d.reload.draft["views"].last["sections"].last["id"] }
    patch "/paineis/#{d.id}/rascunho", params: { op: "add_widget", target: s, view_id: v,
                                                 widget: { type: "weather", bind: weather_point.id, forecast: "daily", screens: [ "", "mobile", "tablet" ] } }
    patch "/paineis/#{d.id}/rascunho", params: { op: "add_widget", target: s, view_id: v,
                                                 widget: { type: "markdown", text: %(Luz: **{{ points["sala.luz"].text }}**) } }
    widgets = within(tenant) { d.reload.draft["views"].last["sections"].last["widgets"] }
    expect(widgets[0]).to include("type" => "weather", "bind" => weather_point.id, "forecast" => "daily", "visible_if" => { "screen" => %w[mobile tablet] })
    expect(widgets[1]).to include("type" => "markdown", "text" => %(Luz: **{{ points["sala.luz"].text }}**))
    expect(widgets[1]).not_to have_key("visible_if")

    # Condição de estado vinda do JSON continua depois de salvar pelo formulário.
    within(tenant) do
      draft = d.reload.draft
      draft["views"].last["sections"].last["widgets"][1]["visible_if"] = { "state" => { "point" => lamp.id, "is" => [ true ] } }
      d.update!(draft: draft)
    end
    patch "/paineis/#{d.id}/rascunho", params: { op: "update_widget", target: widgets[1]["id"], view_id: v,
                                                 widget: { type: "markdown", text: %(Luz: **{{ points["sala.luz"].text }}**), roles: [ "", "owner" ], screens: [ "" ] } }
    md = within(tenant) { d.reload.draft["views"].last["sections"].last["widgets"][1] }
    expect(md["visible_if"]).to eq("state" => { "point" => lamp.id, "is" => [ true ] }, "role" => [ "owner" ])

    post "/paineis/#{d.id}/publicar"
    get "/paineis/#{d.id}", params: { view: v }
    expect(response.body).to include("dw-weather", "Chuva", "21°", "Hoje", "90%", "dw-hide-desktop", "Luz: <strong>Ligado</strong>")
    get "/paineis/#{d.id}/w/#{md['id']}"
    expect(response.body).to include("<strong>Ligado</strong>")
  end

  it "editor de automação: adiciona e preenche Ler previsão do tempo" do
    post "/locais/#{site.id}/integracoes", params: { tipo: "weather", integration: { provider: "open_meteo" } }
    a = within(tenant) { Automation.create!(site: site, name: "Teste Lote4 editor", kind: "automation") }
    patch "/automacoes/#{a.id}/rascunho", params: { op: "add", target: "actions", type: "weather_forecast" }
    patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "actions.0", block: { point: weather_point.id, kind: "hourly", count: "6", response_variable: "tempo" } }
    expect(within(tenant) { a.reload.draft["actions"][0] }).to include("type" => "weather_forecast", "point" => weather_point.id, "kind" => "hourly", "count" => 6, "response_variable" => "tempo")
    get "/automacoes/#{a.id}/editar"
    expect(response.body).to include("Ler previsão do tempo", "Por hora", "Devolve na variável")
  end
end
