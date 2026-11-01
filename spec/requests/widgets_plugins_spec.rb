require "rails_helper"

# Widgets só por registro: os 13 tipos da F5 são plugins como os do Lote 4, e
# um tipo novo (falso, por stub_const) entra no Schema, no editor e no
# Resolver sem mexer no núcleo.
RSpec.describe "Widgets do painel por registro" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:lamp) { within(tenant) { create(:point, device: create(:device, site: site, name: "Sala"), name: "Luz", key: "sala.luz", capability: "measure", value: 7) } }

  before { post("/entrar", params: { email: user.email, password: "12345678" }) }

  it "os tipos da F5 vêm do registro, com nome e ícone" do
    f5 = %w[heading tile group stat gauge chart query_list area_card scene_bar alerts camera vacuum energy]
    expect(Dashboards::Schema.types.keys).to include(*f5)
    expect(Dashboards::Schema.types.keys).to eq(Dashboards::Widgets.plugins.map(&:type))
    expect(Dashboards::Schema.labels).to include("tile" => "Ponto", "energy" => "Consumo e custo", "heading" => "Título")
    expect(Dashboards::Widgets["tile"].icon).to eq("light-bulb")
    expect(Dashboards::Schema.const_defined?(:WIDGETS)).to be(false)
  end

  it "tipo novo por stub_const: valida, aparece no editor, salva pelo formulário e resolve" do
    fake = Class.new(Dashboards::Widgets::Base) do
      describe type: "contador_falso", label: "Contador falso", icon: "calculator", required: %w[bind], params: %w[title], bind: true
      def self.errors(w) = w["title"].to_s.size > 10 ? [ "título longo" ] : []
      def self.data(_r, w, binds) = [ { "text" => "#{w['title']}: #{binds.first&.value}" }, [] ]
      def self.partial = "web/dashboards/widgets/markdown"
      def self.form = "web/dashboards/widget_forms/heading" # reaproveita o campo Título
    end
    stub_const("Dashboards::Widgets::ContadorFalso", fake)
    stub_const("Dashboards::Widgets::PLUGINS", Dashboards::Widgets::PLUGINS + %w[ContadorFalso])

    expect(Dashboards::Schema.labels).to include("contador_falso" => "Contador falso")
    expect(Dashboards::Schema.types).to include("contador_falso" => %w[bind])

    d = within(tenant) { Dashboard.ensure_for(site).first }
    get "/paineis/#{d.id}/editar"
    expect(response.body).to include(%(<option value="contador_falso">Contador falso</option>),
                                     "[data-for~=contador_falso]", %(data-for="heading contador_falso"))
    patch "/paineis/#{d.id}/rascunho", params: { op: "add_view", title: "Teste" }
    v = within(tenant) { d.reload.draft["views"].last["id"] }
    patch "/paineis/#{d.id}/rascunho", params: { op: "add_section", view_id: v, title: "Teste" }
    s = within(tenant) { d.reload.draft["views"].last["sections"].last["id"] }
    patch "/paineis/#{d.id}/rascunho", params: { op: "add_widget", target: s, view_id: v, widget: { type: "contador_falso", bind: lamp.id, title: "Sala" } }
    draft = within(tenant) { d.reload.draft }
    expect(draft["views"].last["sections"].last["widgets"].last).to include("type" => "contador_falso", "bind" => lamp.id, "title" => "Sala")
    expect(Dashboards::Schema.errors(draft)).to eq([])

    long = draft.deep_dup.tap { |x| x["views"].last["sections"].last["widgets"].last["title"] = "x" * 11 }
    expect(Dashboards::Schema.errors(long)).to eq([ "widget #{draft['views'].last['sections'].last['widgets'].last['id']} (seção #{s}): título longo" ])

    w = within(tenant) { Dashboards::Resolver.new(d, role: "owner", definition: draft).call }["views"].last["sections"].last["widgets"].last
    expect(w).to include("data" => { "text" => "Sala: 7" }, "deps" => [ lamp.id ])
  end
end
