require "rails_helper"

# ondaB1: telas e API do assistente de voz (pipelines, depuração, frases,
# satélites e servidor MCP).
RSpec.describe "Web ondaB1: assistente de voz" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let(:site) { within(tenant) { create(:site) } }
  let!(:luz) { within(tenant) { create(:point, site: site, device: create(:device, site: site, area: create(:area, site: site, name: "Sala")), name: "Luz", value: false) } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  before do
    Onboarding.finish!(tenant)
    sign_in
  end

  it "B5: pipelines (criar, mudar, remover), depuração com a execução e o teste de frase" do
    get "/locais/#{site.id}/assistente"
    expect(response.body).to include("Assistente de voz", "Novo pipeline", "Voz para texto", "Texto para fala")
    post "/locais/#{site.id}/assistente/pipelines", params: { pipeline: { name: "Teste casa", language: "en", agent: "local", preferred: "1", stt_engine: "installation",
                                                                          stt: { installation: { provider: "" } }, tts_engine: "" } }
    pl = within(tenant) { AssistPipeline.find_by!(name: "Teste casa") }
    expect(pl).to have_attributes(language: "en", preferred: true, stt: { "engine" => "installation" }, tts: {})
    patch "/locais/#{site.id}/assistente/pipelines/#{pl.id}", params: { pipeline: { name: "Teste casa", language: "pt-BR", agent: "local_llm" } }
    expect(pl.reload).to have_attributes(language: "pt-BR", agent: "local_llm")
    get "/locais/#{site.id}/assistente"
    expect(response.body).to include("Preferido", "Local, depois IA com ferramentas")

    post "/assistente", params: { site_id: site.id, text: "ligar a luz da sala" }, as: :json
    expect(response.parsed_body).to include("text" => "Liguei Luz.", "run_id" => be_present)
    get "/locais/#{site.id}/assistente", params: { aba: "depuracao" }
    expect(response.body).to include("ligar a luz da sala", "Liguei Luz.", "turn_on", "vz-seg-intent")

    commands = within(tenant) { Command.count }
    get "/locais/#{site.id}/assistente", params: { aba: "frases", texto: "deixe a luz da sala em 30%", idioma: "pt-BR" }
    expect(response.body).to include("light_brightness", "brightness", "30", "Intenções nativas")
    expect(within(tenant) { Command.count }).to eq(commands) # testar não executa
    get "/locais/#{site.id}/assistente", params: { aba: "frases", modelo: "abrir [a] {porta}", exemplo: "abrir a garagem" }
    expect(response.body).to include("Casa com o exemplo", "garagem")
    get "/locais/#{site.id}/assistente", params: { aba: "frases", modelo: "abrir [a {porta}", exemplo: "x" }
    expect(response.body).to include("Colchetes ou parênteses sem par.")

    delete "/locais/#{site.id}/assistente/pipelines/#{pl.id}"
    expect(within(tenant) { AssistPipeline.count }).to eq(0)
  end

  it "B6: satélites (criar, testar, remover) e o motor Wyoming no pipeline" do
    get "/locais/#{site.id}/assistente", params: { aba: "satelites" }
    expect(response.body).to include("Novo satélite", "Satélite Wyoming", "Satélite ESPHome")
    area = within(tenant) { site.areas.first }
    post "/locais/#{site.id}/assistente/satelites", params: { satellite: { name: "Teste cozinha", kind: "wyoming", host: "127.0.0.1", port: "1", area_id: area.id, role: "resident", enabled: "1" } }
    sat = within(tenant) { AssistSatellite.find_by!(name: "Teste cozinha") }
    expect(sat).to have_attributes(area_id: area.id, port: 1, role: "resident")
    post "/locais/#{site.id}/assistente/satelites/#{sat.id}/testar"
    expect(flash[:alert]).to include("Wyoming 127.0.0.1:1")
    get "/locais/#{site.id}/assistente", params: { aba: "satelites" }
    expect(response.body).to include("Teste cozinha", "Sem conexão", "Wyoming 127.0.0.1:1")
    post "/locais/#{site.id}/assistente/satelites", params: { satellite: { name: "Teste sem", kind: "wyoming", host: "" } }
    expect(flash[:alert]).to be_present
    delete "/locais/#{site.id}/assistente/satelites/#{sat.id}"
    expect(within(tenant) { AssistSatellite.count }).to eq(0)

    post "/locais/#{site.id}/assistente/pipelines", params: { pipeline: { name: "Teste local", language: "pt-BR", agent: "local", stt_engine: "wyoming",
                                                                          stt: { wyoming: { host: "wyoming-whisper", port: "10300", model: "small" } }, tts_engine: "wyoming",
                                                                          tts: { wyoming: { host: "wyoming-piper", voice: "pt_BR-faber-medium", model: "ignorado" } } } }
    pl = within(tenant) { AssistPipeline.find_by!(name: "Teste local") }
    expect(pl.stt).to eq("engine" => "wyoming", "host" => "wyoming-whisper", "port" => "10300", "model" => "small")
    expect(pl.tts).to eq("engine" => "wyoming", "host" => "wyoming-piper", "voice" => "pt_BR-faber-medium")
    get "/locais/#{site.id}/assistente"
    expect(response.body).to include("Wyoming (Whisper, Piper, openWakeWord)", "wyoming-piper")
  end

  it "B5: em inglês a tela sai em inglês; quem não é técnico não entra" do
    user.update!(dashboard_prefs: { "locale" => "en" })
    get "/locais/#{site.id}/assistente", params: { aba: "frases" }
    expect(response.body).to include("Voice assistant", "Try a sentence", "Built-in intents (English)")
    member = within(tenant) { create(:user, tenant: tenant, role: "member") }
    within(tenant) { create(:site_membership, site: site, user: member, role: "resident") }
    sign_in(member)
    get "/locais/#{site.id}/assistente"
    expect(response).to have_http_status(:forbidden).or redirect_to(anything)
  end
end
