require "rails_helper"

# voz-offline: aba Testar (fale e veja, tempo de cada etapa), "modo offline"
# no botão Falar e na API do app, e o pipeline que proíbe a nuvem.
RSpec.describe "Web e API voz-offline" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let(:site) { within(tenant) { create(:site) } }
  let!(:luz) { within(tenant) { create(:point, site: site, device: create(:device, site: site, area: create(:area, site: site, name: "Sala")), name: "Luz", value: false) } }
  let(:wav) { Wyoming.wav("\x00\x00".b * 1600, 16_000, 2, 1) }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  def offline!
    allow(Internet).to receive(:probe).and_return(false)
    Internet.reset!
  end

  before { Onboarding.finish!(tenant) }

  describe "web" do
    before { sign_in }

    it "aba Testar: texto sem executar mostra a intenção e as etapas; executar comanda; o tempo aparece" do
      get "/locais/#{site.id}/assistente", params: { aba: "testar" }
      expect(response.body).to include("Fale e veja", "Com internet", "Voz para texto", "Tempo de resposta", "data-controller=\"assist-test\"")
      post "/locais/#{site.id}/assistente/testar", params: { texto: "ligar a luz da sala", falar: "0" }
      expect(response.body).to include("turn_on", "Entendi:", "Etapas e tempo", "Intenção")
      expect(luz.reload.value).to be false
      post "/locais/#{site.id}/assistente/testar", params: { texto: "ligar a luz da sala", falar: "0", executar: "1" }
      expect(response.body).to include("Liguei Luz.")
      expect(luz.reload.value).to be true
      get "/locais/#{site.id}/assistente", params: { aba: "depuracao" }
      expect(response.body).to include("Tempo de resposta", "Teste")
    end

    it "aba Testar com áudio pelo Whisper local, a verificação dos servidores e o erro sem voz" do
      within(tenant) { AiAccount.create!(provider: "wyoming", base_url: "tcp://192.0.2.10") }
      allow(Wyoming).to receive(:transcribe).and_return("ligar a luz da sala")
      allow(Wyoming).to receive(:synthesize).and_return({ data: wav, media_type: "audio/wav" })
      allow(Wyoming).to receive(:describe).and_return({ "tts" => [ { "name" => "piper" } ] })
      offline!
      post "/locais/#{site.id}/assistente/testar", params: { audio: Rack::Test::UploadedFile.new(StringIO.new(wav), "audio/wav", original_filename: "fala.wav") }
      expect(response.body).to include("Modo offline", "ligar a luz da sala", "wyoming", "local", "<audio controls")
      get "/locais/#{site.id}/assistente", params: { aba: "testar", verificar: 1 }
      expect(response.body).to include("192.0.2.10", "10300", "piper", "Local (na casa)")

      within(tenant) { AiAccount.where(provider: "wyoming").delete_all && AiAccount.create!(provider: "openai", api_key: "sk") }
      post "/locais/#{site.id}/assistente/testar", params: { audio: Rack::Test::UploadedFile.new(StringIO.new(wav), "audio/wav", original_filename: "fala.wav") }
      expect(response.body).to include("O teste falhou", "Whisper")
    end

    it "pipeline sem nuvem e agente só comandos da casa" do
      post "/locais/#{site.id}/assistente/pipelines", params: { pipeline: { name: "Casa fechada", language: "pt-BR", agent: "intents", cloud: "0", preferred: "1" } }
      pl = within(tenant) { AssistPipeline.find_by!(name: "Casa fechada") }
      expect(pl).to have_attributes(cloud: false, agent: "intents")
      get "/locais/#{site.id}/assistente"
      expect(response.body).to include("Pode usar a nuvem", "Só os comandos da casa", "Automático (local primeiro)")
    end

    it "botão Falar: estado (modo offline) e a resposta trazendo `offline`" do
      get "/locais/#{site.id}/assistente"
      expect(response.body).to include("data-assist-status-url-value", "Modo offline")
      get "/assistente/estado", params: { site_id: site.id }
      expect(response.parsed_body).to include("offline" => false)
      offline!
      get "/assistente/estado", params: { site_id: site.id }
      expect(response.parsed_body).to include("offline" => true, "stt" => { "mode" => "none" })
      post "/assistente", params: { site_id: site.id, text: "ligar a luz da sala" }, as: :json
      expect(response.parsed_body).to include("text" => "Liguei Luz.", "offline" => true)
    end
  end

  describe "API do app" do
    it "GET status e o assist com `offline`" do
      offline!
      get "/api/v1/sites/#{site.id}/assist/status", headers: auth_headers(user)
      expect(data).to include("offline" => true, "ai" => { "mode" => "none" })
      post "/api/v1/sites/#{site.id}/assist", params: { text: "conte uma piada" }, headers: auth_headers(user)
      expect(data).to include("intent" => "offline", "offline" => true)
    end
  end
end
