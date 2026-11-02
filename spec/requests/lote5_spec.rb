require "rails_helper"

# Lote 5: telas do que entrou (voz em Configurações → IA, entrada de cena no
# blueprint importado, sensor calculado com "a cada" e atributos, atributo
# no widget Número).
RSpec.describe "Lote 5: telas" do
  let(:user) { create(:user, name: "Dona") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Local") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Virtual", driver: "virtual") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, site: site, key: "sala.luz", name: "Luz", writable: true, value: true) } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  before { sign_in }

  it "Configurações → IA: voz local aparece com as capacidades e o teste gera uma fala" do
    within(tenant) do
      tenant.update!(http_allow_text: "192.168.68.60")
      AiAccount.create!(provider: "local_audio", base_url: "http://192.168.68.60:8000/v1")
    end
    get "/configuracoes/ia"
    expect(response.body).to include("Voz local (Whisper / Piper)", "Voz para texto", "Texto para fala")
    stub_request(:post, "http://192.168.68.60:8000/v1/audio/speech").to_return(body: "MP3")
    post "/configuracoes/ia/local_audio/teste"
    expect(flash[:notice]).to include("gerou a fala", "tts-1", "3 bytes")
  end

  it "blueprint importado com cena: a tela oferece as cenas do local e cria a automação" do
    scene = within(tenant) { site.scenes.create!(name: "Noite", items: [ { "point_id" => lamp.id, "command" => "off" } ]) }
    yaml = "alias: Noite\ntriggers: [ { trigger: homeassistant, event: start } ]\nactions: [ { action: scene.turn_on, target: { entity_id: scene.noite } } ]\n"
    post "/locais/#{site.id}/blueprints", params: { yaml: yaml }
    bp = within(tenant) { site.blueprints.last }
    get "/blueprints/#{bp.id}/usar"
    expect(response.body).to include("Noite", "Escolha")
    post "/blueprints/#{bp.id}/usar", params: { name: "Noite ao iniciar", inputs: { scene_noite: scene.id } }
    a = within(tenant) { site.automations.find_by!(name: "Noite ao iniciar") }
    expect(a.definition).to eq("triggers" => [ { "type" => "system", "event" => "start" } ], "conditions" => [], "actions" => [ { "type" => "scene", "scene" => scene.id } ])
  end

  it "helper calculado com a cada e atributos, e o widget Número com atributo" do
    get "/locais/#{site.id}/helpers/novo", params: { tipo: "template" }
    expect(response.body).to include("A cada (opcional)", "Atributos (opcional)", "previous")
    post "/locais/#{site.id}/helpers", params: { tipo: "template", helper: { name: "Resumo", kind: "text", expr: "{{ points[\"sala.luz\"].text }}", every: "",
                                                                         attrs: "frase: Luz {{ points[\"sala.luz\"].text }}" } }
    expect(response).to redirect_to("/locais/#{site.id}/helpers")
    resumo = within(tenant) { site.points.find_by!(name: "Resumo") }
    expect(resumo.attrs).to eq("frase" => "Luz Ligado")
    get "/helpers/#{resumo.id}/editar"
    expect(response.body).to include("frase: Luz")

    dash = within(tenant) { Dashboard.create!(site: site, name: "P", kind: "home", definition: { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => [] } ] } ] }) }
    get "/paineis/#{dash.id}/editar"
    expect(response.body).to include("widget[attribute]")
  end
end
