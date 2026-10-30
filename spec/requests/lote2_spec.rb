require "rails_helper"

# Lote 2: telas de Configurações → IA, Perguntar à casa, Dados (conjuntos e
# CSV), helper Consulta e o editor das ações de IA e de dados.
RSpec.describe "Lote 2: telas de IA e dados" do
  let(:user) { create(:user, name: "Dona") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Local") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Virtual", driver: "virtual") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, site: site, key: "sala.luz", name: "Luz", writable: true, value: true) } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  def anthropic_ok(text = "OK")
    stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
      headers: { "Content-Type" => "application/json" },
      body: { id: "m", type: "message", role: "assistant", model: "claude-sonnet-5-5", stop_reason: "end_turn",
              content: [ { type: "text", text: text } ], usage: { input_tokens: 12, output_tokens: 2 } }.to_json
    )
  end

  before { sign_in }

  describe "Configurações → IA" do
    it "lista os provedores do registro (inclusive um plugin novo), guarda a chave cifrada e nunca a mostra" do
      fake = Class.new(Ai::Providers::Base) { describe key: "eco", label: "Eco de teste", default_model: "eco-1", capabilities: %i[text], key_required: false }
      stub_const("Ai::Providers::Eco", fake)
      stub_const("Ai::PROVIDERS", Ai::PROVIDERS + %w[Eco])
      get "/configuracoes/ia"
      expect(response.body).to include("Anthropic (Claude)", "OpenAI", "Google Gemini", "Ollama (local)", "Eco de teste", "Saída estruturada (JSON schema)",
                                       "Nenhuma chamada ainda", "Sem limite")

      patch "/configuracoes/ia/anthropic", params: { account: { api_key: "sk-ant-segredo", model: "claude-haiku-5-5", enabled: "1" } }
      acc = within(tenant) { AiAccount.find_by!(provider: "anthropic") }
      expect([ acc.api_key, acc.model ]).to eq([ "sk-ant-segredo", "claude-haiku-5-5" ])
      expect(AiAccount.connection.select_value("select api_key from ai_accounts where id = '#{acc.id}'")).not_to include("sk-ant-segredo")
      get "/configuracoes/ia"
      expect(response.body).not_to include("sk-ant-segredo")
      expect(response.body).to include("Guardada (cifrada)", "Testar conexão")

      patch "/configuracoes/ia/anthropic", params: { account: { api_key: "", model: "" } } # vazio mantém a chave
      expect(acc.reload.api_key).to eq("sk-ant-segredo")
      patch "/configuracoes/ia/ollama", params: { account: { base_url: "ftp://x" } }
      expect(flash[:alert]).to be_present
      patch "/configuracoes/ia/nada", params: { account: { api_key: "x" } }
      expect(flash[:alert]).to eq("Provedor desconhecido.")
      patch "/configuracoes/ia/anthropic", params: { account: { remove_key: "1", enabled: "0" } }
      expect(acc.reload).to have_attributes(api_key: nil, enabled: false)
    end

    it "testar conexão registra a chamada, marca o teste e mostra no uso; erro fica no cartão" do
      within(tenant) { AiAccount.create!(provider: "anthropic", api_key: "sk") }
      anthropic_ok
      post "/configuracoes/ia/anthropic/teste"
      expect(flash[:notice]).to include("respondeu")
      get "/configuracoes/ia"
      expect(response.body).to include("Testado", "Teste de conexão", "claude-sonnet-5-5")

      stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(status: 500, body: "{}", headers: { "Content-Type" => "application/json" })
      post "/configuracoes/ia/anthropic/teste"
      expect(flash[:alert]).to include("Anthropic")
      get "/configuracoes/ia"
      expect(response.body).to include("Com erro")
      post "/configuracoes/ia/openai/teste"
      expect(flash[:alert]).to include("Salve a chave")
    end

    it "salva padrão e limite; membro não entra e administrador só vê" do
      patch "/configuracoes/ia", params: { ai: { default_provider: "gemini", limit_usd: "2,5", limit_calls: "100" } }
      expect(tenant.reload.settings["ai"]).to eq("default_provider" => "gemini", "limit_usd" => 2.5, "limit_calls" => 100)
      get "/configuracoes/ia"
      expect(response.body).to include("US$ 2,50", "/ 100", 'role="progressbar"')

      admin = create(:user, tenant: tenant, role: "admin")
      sign_in(admin)
      get "/configuracoes/ia"
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Salvar padrão e limite")
      patch "/configuracoes/ia", params: { ai: { limit_usd: "9" } }
      expect(tenant.reload.settings.dig("ai", "limit_usd")).to eq(2.5)

      sign_in(create(:user, tenant: tenant, role: "member"))
      get "/configuracoes/ia"
      expect(response).to redirect_to("/configuracoes")
    end
  end

  describe "Perguntar à casa" do
    it "responde com os pontos do local no contexto; sem IA explica; só leitura" do
      get "/perguntar"
      expect(response.body).to include("Perguntar à casa", "Só responde, não executa comandos")
      post "/perguntar", params: { site_id: site.id, question: "Tem luz acesa?" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Nenhum provedor de IA configurado", "Configurar a IA")

      within(tenant) { AiAccount.create!(provider: "anthropic", api_key: "sk") }
      anthropic_ok("Sim, a Luz da sala está ligada.")
      post "/perguntar", params: { site_id: site.id, question: "Tem luz acesa?" }
      expect(response.body).to include("Sim, a Luz da sala está ligada.", "claude-sonnet-5-5")
      expect(a_request(:post, "https://api.anthropic.com/v1/messages").with { |r| r.body.include?("Luz [sala.luz]") && r.body.include?("Tem luz acesa?") }).to have_been_made
      expect(within(tenant) { AiCall.sole }).to have_attributes(source: "pergunta", site_id: site.id)

      post "/perguntar", params: { site_id: site.id, question: " " }
      expect(response).to have_http_status(:unprocessable_content)
      other = within(create(:tenant)) { create(:site) }
      post "/perguntar", params: { site_id: other.id, question: "x" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "Dados" do
    it "cria conjunto, lista registros com filtro, exporta CSV, edita e exclui" do
      get "/locais/#{site.id}/dados"
      expect(response.body).to include("Nenhum conjunto de dados")
      get "/locais/#{site.id}/dados/novo"
      expect(response.body).to include("Guardar por (dias)")
      post "/locais/#{site.id}/dados", params: { dataset: { name: "", fields_text: "" } }
      expect(response).to have_http_status(:unprocessable_content)
      post "/locais/#{site.id}/dados", params: { dataset: { name: "Aberturas", fields_text: "porta: texto\nminutos: número", retention_days: "30" } }
      ds = within(tenant) { Dataset.find_by!(key: "aberturas") }
      expect(response).to redirect_to("/dados/#{ds.id}")
      within(tenant) do
        ds.record!({ "porta" => "garagem", "minutos" => 5 })
        ds.record!({ "porta" => "=cmd()", "minutos" => 12 })
      end

      get "/locais/#{site.id}/dados"
      expect(response.body).to include("Aberturas", "porta, minutos", "guarda 30 dias")
      get "/dados/#{ds.id}"
      expect(response.body).to include("garagem", "Exportar CSV")
      get "/dados/#{ds.id}", params: { filtros: "minutos > 10", dias: "7" }
      expect(response.body).not_to include(">garagem<")
      get "/dados/#{ds.id}", params: { filtros: "lixo" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("filtro inválido")

      get "/dados/#{ds.id}.csv"
      expect(response.media_type).to eq("text/csv")
      lines = response.body.lines.map(&:chomp)
      expect(lines.first).to eq("em,porta,minutos")
      expect(lines).to include(a_string_ending_with(",'=cmd(),12"), a_string_ending_with(",garagem,5"))

      get "/dados/#{ds.id}/editar"
      expect(response.body).to include("Excluir conjunto")
      patch "/dados/#{ds.id}", params: { dataset: { name: "Aberturas do portão", fields_text: "porta: cor" } }
      expect(response).to have_http_status(:unprocessable_content)
      patch "/dados/#{ds.id}", params: { dataset: { name: "Aberturas do portão", retention_days: "" } }
      expect(ds.reload).to have_attributes(name: "Aberturas do portão", retention_days: nil)
      delete "/dados/#{ds.id}"
      expect(within(tenant) { [ Dataset.count, DatasetRecord.count ] }).to eq([ 0, 0 ])
    end

    it "convidado vê, mas não cria" do
      guest = create(:user, tenant: tenant, role: "member")
      within(tenant) { create(:site_membership, site: site, user: guest, role: "guest") }
      sign_in(guest)
      get "/locais/#{site.id}/dados"
      expect(response).to have_http_status(:ok)
      post "/locais/#{site.id}/dados", params: { dataset: { name: "X" } }
      expect(within(tenant) { Dataset.count }).to eq(0)
    end

    it "helper Consulta: formulário e criação" do
      ds = within(tenant) { Dataset.create!(site: site, name: "Contagens") }
      get "/locais/#{site.id}/helpers/novo", params: { tipo: "dataset_query" }
      expect(response.body).to include("Conjunto de dados", "Contagens", "Operadores: &gt;= &lt;= != = &gt; &lt; contém")
      post "/locais/#{site.id}/helpers", params: { tipo: "dataset_query", helper: { name: "Total", dataset: ds.id, op: "count", window: "", filters: "" } }
      expect(response).to redirect_to("/locais/#{site.id}/helpers")
      expect(within(tenant) { site.points.find_by!(name: "Total") }).to have_attributes(helper: "dataset_query", value: 0)
    end
  end

  describe "editor das ações de IA e de dados" do
    it "adiciona e preenche Pedir à IA, Gerar dados por IA, Registrar e Consultar dados pelo formulário" do
      cam = within(tenant) { create(:point, device: create(:device, site: site, driver: "go2rtc", name: "DVR"), key: "dvr.cam", capability: "stream", name: "Entrada") }
      area = within(tenant) { create(:area, site: site, name: "Sala") }
      ds = within(tenant) { Dataset.create!(site: site, name: "Log") }
      a = within(tenant) { Automation.create!(site: site, name: "Teste Lote2 editor", kind: "automation") }
      %w[ai_task ai_data dataset_record dataset_query].each { |t| patch "/automacoes/#{a.id}/rascunho", params: { op: "add", target: "actions", type: t } }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "actions.0",
                                                      block: { prompt: "Viu alguém? {{ trigger.point }}", cameras: [ "", cam.id ], image_urls: "", provider: "anthropic",
                                                               output: "pessoas: inteiro quantas\nresumo: texto", temperature: "0,4", max_tokens: "300" } }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "actions.1", block: { prompt: "Resumo", areas: [ "", area.id ], points: [ "", lamp.id ], history: "168h" } }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "actions.2", block: { dataset: ds.id, values: "porta: {{ trigger.point }}\nlixo sem dois pontos" } }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "actions.3", block: { dataset: ds.id, op: "count", window: "24h", filters: "porta = x" } }
      draft = within(tenant) { a.reload.draft["actions"] }
      expect(draft[0]).to include("cameras" => [ cam.id ], "provider" => "anthropic", "temperature" => 0.4, "max_tokens" => 300,
                                  "output" => [ { "name" => "pessoas", "type" => "inteiro", "description" => "quantas" }, { "name" => "resumo", "type" => "texto" } ])
      expect(draft[1]).to include("areas" => [ area.id ], "points" => [ lamp.id ], "history" => "168h")
      expect(draft[2]["values"]).to eq("porta" => "{{ trigger.point }}")
      expect(draft[3]).to include("op" => "count", "filters" => "porta = x")

      get "/automacoes/#{a.id}/editar"
      expect(response.body).to include("Pedir à IA", "Gerar dados por IA", "Registrar dados", "Consultar dados", "pessoas: inteiro quantas",
                                       "Entrada", "Sala", "pessoas, resumo", "Log", "Contagem", "Devolve na variável")
      within(tenant) { a.update!(draft: a.draft.merge("triggers" => [ { "type" => "manual" } ])) }
      post "/automacoes/#{a.id}/publicar"
      expect(within(tenant) { a.reload.definition["actions"].size }).to eq(4)
      get "/automacoes/#{a.id}/json"
      expect(response.body).to include("dvr.cam", "sala.luz")
    end
  end
end
