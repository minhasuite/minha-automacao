require "rails_helper"

# Editor de painel de arrastar e soltar (uiweb): o layout ao vivo e as ops
# place (ordem e troca de seção) e resize (largura por tela), por fetch (JSON).
RSpec.describe "Editor de painel: arrastar e soltar" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:lamp) { within(tenant) { create(:point, device: create(:device, site: site, name: "Teste Sala"), name: "Luz", key: "teste.luz", value: true) } }
  let(:defn) do
    { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "Início", "sections" => [
      { "id" => "s1", "title" => "Um", "widgets" => [ { "id" => "a", "type" => "tile", "bind" => lamp.id }, { "id" => "b", "type" => "heading", "title" => "B" } ] },
      { "id" => "s2", "title" => "Dois", "widgets" => [ { "id" => "c", "type" => "heading", "title" => "C" } ] }
    ] } ] }
  end
  let!(:dashboard) { within(tenant) { site.dashboards.create!(name: "Teste", kind: "custom", definition: defn).tap { |d| d.publish!(defn) } } }
  let(:json) { { "Accept" => "application/json" } }

  before { post("/entrar", params: { email: user.email, password: "12345678" }) }

  def draft = within(tenant) { dashboard.reload.draft }
  def ids(s) = s["widgets"].pluck("id")

  it "mostra os widgets de verdade no layout ao vivo, com alças" do
    get "/paineis/#{dashboard.id}/editar"
    expect(response.body).to include('data-controller="layout-editor"', 'data-kind="widget"', 'data-id="a"', "dw-ed-resize", "Arrume ao vivo", "inert")
    expect(response.body).to include('data-section="s2"')
  end

  it "place: reordena e troca de seção; resize muda só a tela pedida" do
    patch "/paineis/#{dashboard.id}/rascunho", params: { op: "place", kind: "widget", target: "a", index: 1, parent: "s2", view_id: "v" }, headers: json
    expect(response).to have_http_status(:no_content)
    expect(draft["views"][0]["sections"].map { |s| ids(s) }).to eq([ %w[b], %w[c a] ])

    patch "/paineis/#{dashboard.id}/rascunho", params: { op: "place", kind: "section", target: "s2", index: 0, view_id: "v" }, headers: json
    expect(draft["views"][0]["sections"].pluck("id")).to eq(%w[s2 s1])

    patch "/paineis/#{dashboard.id}/rascunho", params: { op: "resize", kind: "widget", target: "a", screen: "tablet", cols: 99, view_id: "v" }, headers: json
    expect(draft["views"][0]["sections"][0]["widgets"][1]["span"]).to eq("mobile" => 12, "tablet" => 12, "desktop" => 4)
    patch "/paineis/#{dashboard.id}/rascunho", params: { op: "resize", kind: "section", target: "s1", screen: "desktop", cols: 6, view_id: "v" }, headers: json
    expect(draft["views"][0]["sections"][1]["span"]).to eq("mobile" => 12, "tablet" => 12, "desktop" => 6)
    expect(dashboard.reload.definition).to eq(defn) # só o rascunho muda

    patch "/paineis/#{dashboard.id}/rascunho", params: { op: "place", kind: "widget", target: "nada", index: 0, view_id: "v" }, headers: json
    expect(response).to have_http_status(:not_found)
    patch "/paineis/#{dashboard.id}/rascunho", params: { op: "resize", kind: "widget", target: "a", screen: "tv", cols: 3, view_id: "v" }, headers: json
    expect(response).to have_http_status(:not_found)
  end

  it "quem não edita não arrasta" do
    other = create(:user, tenant: tenant, role: "member")
    within(tenant) { create(:site_membership, site: site, user: other, role: "resident") }
    delete "/sair"
    post("/entrar", params: { email: other.email, password: "12345678" })
    patch "/paineis/#{dashboard.id}/rascunho", params: { op: "place", kind: "section", target: "s2", index: 0 }, headers: json
    expect(response).not_to have_http_status(:no_content)
    expect(within(tenant) { dashboard.reload.draft }).to be_nil
  end
end
