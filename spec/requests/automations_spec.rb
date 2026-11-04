require "rails_helper"

RSpec.describe "Automações (DSL): web e API" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa", latitude: -15.79, longitude: -47.88) } }
  let!(:device) { within(tenant) { create(:device, site: site, name: "Quadro") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Luz", key: "sala.luz", value: false) } }
  let!(:motion) { within(tenant) { create(:point, device: device, name: "Movimento", key: "sala.movimento", capability: "motion", value: false) } }
  let!(:gate) { within(tenant) { create(:point, device: device, name: "Portão", key: "garagem.portao", capability: "gate", value: "closed", risk: "critical") } }

  let(:simple) do
    { "triggers" => [ { "type" => "state", "point" => "sala.movimento", "to" => true } ],
      "conditions" => [ { "type" => "time", "after" => "18:00", "before" => "05:00" } ],
      "actions" => [ { "type" => "command", "point" => "sala.luz", "command" => "on" },
                     { "type" => "notify", "channels" => [ "in_app" ], "title" => "{{ trigger.point }} viu alguém" } ] }
  end

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })
  def member(role) = create(:user, tenant: tenant, role: "member").tap { |u| within(tenant) { create(:site_membership, site: site, user: u, role: role) } }
  def automation = within(tenant) { Automation.sole }
  def draft = automation.draft

  describe "web" do
    before { sign_in }

    it "cria, monta no editor de blocos, publica, liga, simula, executa e mostra o trace" do
      get "/locais/#{site.id}/automacoes"
      expect(response.body).to include("Nenhuma automação neste local")
      get "/locais/#{site.id}/regras"
      expect(response.body).to include("Regras simples", "Blueprints")
      get "/locais/#{site.id}/automacoes/nova"
      post "/locais/#{site.id}/automacoes", params: { automation: { name: "" } }
      expect(response).to have_http_status(:unprocessable_content)
      post "/locais/#{site.id}/automacoes", params: { automation: { name: "Movimento acende", mode: "restart" } }
      a = automation
      expect(response).to redirect_to("/automacoes/#{a.id}/editar")

      get "/automacoes/#{a.id}/editar"
      expect(response.body).to include("Quando", "Só se", "Então", "Falta pelo menos um gatilho", "Adicionar")

      patch "/automacoes/#{a.id}/rascunho", params: { op: "add", target: "triggers", type: "state" }
      expect(response).to redirect_to("/automacoes/#{a.id}/editar?b=triggers.0#b-triggers-0")
      patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "triggers.0", block: { point: motion.id, from: "", to: "true", for: "" } }
      expect(draft["triggers"]).to eq([ { "type" => "state", "point" => motion.id, "to" => true } ])
      patch "/automacoes/#{a.id}/rascunho", params: { op: "add", target: "conditions", type: "time" }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "conditions.0", block: { after: "18:00", before: "05:00", days: [ "", *0..6 ] } }
      expect(draft["conditions"]).to eq([ { "type" => "time", "after" => "18:00", "before" => "05:00" } ])
      patch "/automacoes/#{a.id}/rascunho", params: { op: "add", target: "actions", type: "if" }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "add", target: "actions.0.conditions", type: "state" }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "actions.0.conditions.0", block: { point: lamp.id, is: "false", quality: "", for: "1m" } }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "add", target: "actions.0.then", type: "command" }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "actions.0.then.0", block: { point: lamp.id, command: "on", value: "" } }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "add", target: "actions", type: "notify" }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "actions.1", block: { channels: [ "", "in_app" ], title: "Movimento", message: "" } }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "move", target: "actions.1", dir: "up" }
      expect(draft["actions"].pluck("type")).to eq(%w[notify if])
      expect(draft["actions"][1]).to eq("type" => "if", "conditions" => [ { "type" => "state", "point" => lamp.id, "is" => false, "for" => "1m" } ],
                                        "then" => [ { "type" => "command", "point" => lamp.id, "command" => "on" } ])
      patch "/automacoes/#{a.id}/rascunho", params: { op: "add", target: "actions", type: "wait" }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "duplicate", target: "actions.2" }
      expect(response).to redirect_to("/automacoes/#{a.id}/editar?b=actions.3#b-actions-3")
      expect(draft["actions"].pluck("type")).to eq(%w[notify if wait wait])
      patch "/automacoes/#{a.id}/rascunho", params: { op: "remove", target: "actions.3" }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "remove", target: "actions.2" }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "actions.9", block: {} }
      expect(flash[:alert]).to eq("Esse bloco não existe mais no rascunho.")

      get "/automacoes/#{a.id}/editar", params: { b: "actions.1" }
      expect(response.body).to include("Se / senão", "Luz · está Desligado · há pelo menos 1 min", "Salvar bloco", 'data-id="actions.1"', "ss-blk is-focused")
      # Ações do bloco no servidor (Ss::BlockComponent): mover, duplicar, remover com confirmação e a chave.
      html = Nokogiri::HTML5(response.body)
      blk = html.at_css("li#b-actions-1")
      expect(blk["data-id"]).to eq("actions.1")
      expect(blk.at_css("form[action='/automacoes/#{a.id}/rascunho?op=move&target=actions.1'] input[name=dir][value=up]")).to be_present
      expect(blk.at_css("a[href='/automacoes/#{a.id}/rascunho?op=duplicate&target=actions.1'][data-turbo-method=post]")).to be_present
      expect(blk.at_css("form[action='/automacoes/#{a.id}/rascunho?op=remove&target=actions.1'][data-turbo-confirm-tone=danger]")).to be_present
      expect(blk.at_css(".ss-blk-tools form[action='/automacoes/#{a.id}/rascunho'] input[name=op][value=toggle]")).to be_present
      post "/automacoes/#{a.id}/rascunho", params: { op: "duplicate", target: "actions.0" }
      expect(draft["actions"].pluck("type")).to eq(%w[notify notify if])
      patch "/automacoes/#{a.id}/rascunho", params: { op: "remove", target: "actions.1" }
      expect(response.body).not_to include("Falta para publicar")

      post "/automacoes/#{a.id}/publicar"
      expect(automation).to have_attributes(version: 1, draft: nil, enabled: false)
      patch "/automacoes/#{a.id}", params: { automation: { enabled: "true" }, back: "/locais/#{site.id}/automacoes" }
      expect(response).to redirect_to("/locais/#{site.id}/automacoes")
      expect(automation.enabled).to be true
      get "/locais/#{site.id}/automacoes"
      expect(response.body).to include("Movimento acende", "nunca rodou", "Desligar")

      get "/automacoes/#{a.id}/simular"
      expect(response.body).to include("Valores hipotéticos", "Movimento", "Luz")
      post "/automacoes/#{a.id}/simular", params: { at: "2026-10-29T21:00", points: { "sala.movimento" => "true", "sala.luz" => "" } }
      run = within(tenant) { AutomationRun.find_by(dry_run: true) }
      expect(response).to redirect_to("/execucoes/#{run.id}")
      follow_redirect!
      expect(response.body).to include("Simulação", "Condições atendidas", "Horário depois de 18:00, antes de 05:00", "Ligar Luz", "Não enviado (simulação)")
      expect(within(tenant) { lamp.reload.value }).to be false

      post "/automacoes/#{a.id}/executar"
      run = within(tenant) { AutomationRun.real.sole }
      expect(response).to redirect_to("/execucoes/#{run.id}")
      expect(within(tenant) { lamp.reload.value }).to be true
      get "/automacoes/#{a.id}/execucoes"
      expect(response.body).to include("Executar agora", "Concluída", "Simulação")
      get "/execucoes/#{run.id}"
      expect(response.body).to include("Condições ignoradas (executar agora)", "Avisar: Movimento")
    end

    it "JSON avançado com chaves, versões, descartar, webhook e excluir" do
      a = within(tenant) { site.automations.create!(name: "JSON") }
      get "/automacoes/#{a.id}/json"
      expect(response.body).to include("&quot;triggers&quot;: []")
      patch "/automacoes/#{a.id}/json", params: { definition: "{ nada" }
      expect(response.body).to include("JSON inválido")
      patch "/automacoes/#{a.id}/json", params: { definition: { "triggers" => [ { "type" => "nada" } ] }.to_json }
      expect(response.body).to include("tipo &quot;nada&quot; não existe")
      patch "/automacoes/#{a.id}/json", params: { definition: simple.to_json }
      expect(draft["triggers"].first["point"]).to eq(motion.id)
      get "/automacoes/#{a.id}/json"
      expect(response.body).to include("sala.movimento")

      post "/automacoes/#{a.id}/publicar"
      patch "/automacoes/#{a.id}/json", params: { definition: simple.merge("triggers" => [ { "type" => "webhook" } ]).to_json }
      post "/automacoes/#{a.id}/publicar"
      expect(automation.version).to eq(2)
      post "/automacoes/#{a.id}/voltar", params: { version: 1 }
      expect(automation).to have_attributes(version: 3)
      expect(automation.definition["triggers"].first["type"]).to eq("state")

      patch "/automacoes/#{a.id}/json", params: { definition: simple.merge("triggers" => [ { "type" => "webhook" } ]).to_json }
      get "/automacoes/#{a.id}/editar"
      expect(response.body).to include("Webhook", "Gerar endereço", "Descartar rascunho")
      post "/automacoes/#{a.id}/webhook"
      expect(flash[:webhook_url]).to match(%r{/api/v1/hooks/automations/.{20,}})
      post "/automacoes/#{a.id}/descartar"
      expect(automation.draft).to be_nil

      delete "/automacoes/#{a.id}"
      expect(within(tenant) { Automation.count }).to eq(0)
    end

    it "não publica com erro; portão (crítico) pede a confirmação" do
      a = within(tenant) { site.automations.create!(name: "Portão", draft: { "triggers" => [ { "type" => "manual" } ], "actions" => [] }) }
      post "/automacoes/#{a.id}/publicar"
      expect(flash[:alert]).to include("Corrija antes de publicar")
      within(tenant) { a.update!(draft: { "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "command", "point" => gate.id, "command" => "pulse" } ] }) }
      get "/automacoes/#{a.id}/editar"
      expect(response.body).to include("Comanda ponto crítico")
      post "/automacoes/#{a.id}/publicar"
      expect(flash[:alert]).to include("confirme antes")
      expect(automation.version).to eq(0)
      post "/automacoes/#{a.id}/publicar", params: { confirm_critical: "1" }
      expect(automation.version).to eq(1)
      post "/automacoes/#{a.id}/executar"
      expect(flash[:alert]).to include("confirme antes")
    end

    it "papéis: morador vê a lista e as execuções, não edita; visitante não executa o portão" do
      a = within(tenant) { site.automations.create!(name: "Portão").tap { |x| x.publish!({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "command", "point" => gate.id, "command" => "pulse" } ] }) } }
      resident = member("resident")
      sign_in(resident)
      get "/locais/#{site.id}/automacoes"
      expect(response.body).to include("Portão", "/automacoes/#{a.id}/execucoes") # o nome abre as execuções
      expect(response.body).not_to include("Nova automação")
      get "/automacoes/#{a.id}/execucoes"
      expect(response).to have_http_status(:ok)
      get "/automacoes/#{a.id}/editar"
      expect(flash[:alert]).to eq("Seu papel neste local não permite isso.")
      post "/automacoes/#{a.id}/executar", params: { confirm_critical: "1" }
      expect(response).to redirect_to(%r{/execucoes/})

      sign_in(member("guest"))
      post "/automacoes/#{a.id}/executar", params: { confirm_critical: "1" }
      expect(flash[:alert]).to eq("Seu papel neste local não permite isso.")
    end
  end

  describe "API" do
    let(:headers) { auth_headers(user) }

    it "CRUD, publicar, simular, executar, execuções, versões e voltar" do
      post "/api/v1/sites/#{site.id}/automations", params: { name: "x", definition: { "triggers" => [] } }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(json.dig("error", "message")).to include("Falta pelo menos um gatilho")

      post "/api/v1/sites/#{site.id}/automations", params: { name: "Sala", mode: "queued", definition: simple, enabled: true }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      id = data["id"]
      expect(data).to include("version" => 1, "enabled" => true, "mode" => "queued")
      expect(data.dig("definition", "triggers", 0, "point")).to eq(motion.id)

      get "/api/v1/sites/#{site.id}/automations", headers: headers
      expect(data.pluck("name")).to eq([ "Sala" ])
      patch "/api/v1/automations/#{id}", params: { definition: simple.merge("conditions" => []), publish: false }, headers: headers, as: :json
      expect(data).to include("version" => 1, "has_draft" => true)

      post "/api/v1/automations/#{id}/simulate", params: { points: { "sala.movimento" => true } }, headers: headers, as: :json
      expect(data).to include("dry_run" => true, "status" => "done")
      expect(data["steps"].pluck("result")).to include("simulated")
      post "/api/v1/automations/#{id}/simulate", params: { published: true, at: "2026-10-29T12:00:00-03:00" }, headers: headers, as: :json
      expect(data["status"]).to eq("skipped")

      post "/api/v1/automations/#{id}/publish", headers: headers
      expect(data["version"]).to eq(2)
      get "/api/v1/automations/#{id}/versions", headers: headers
      expect(data.pluck("version")).to eq([ 2, 1 ])
      post "/api/v1/automations/#{id}/revert", params: { version: 1 }, headers: headers, as: :json
      expect(data["version"]).to eq(3)

      post "/api/v1/automations/#{id}/run", headers: headers
      expect(response).to have_http_status(:accepted)
      expect(data["status"]).to eq("done")
      run_id = data["id"]
      get "/api/v1/automations/#{id}/runs", headers: headers, params: { dry_run: false }
      expect(data.pluck("id")).to eq([ run_id ])
      expect(json["meta"]).to include("count" => 1)
      get "/api/v1/automation_runs/#{run_id}", headers: headers
      expect(data["steps"].pluck("title")).to include("Ligar Luz")
      get "/api/v1/automations/#{id}", headers: headers
      expect(data).to include("last_status" => "done")

      delete "/api/v1/automations/#{id}", headers: headers
      expect(response).to have_http_status(:no_content)
    end

    it "ponto crítico: papel e confirm_critical" do
      gate_def = { "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "command", "point" => "garagem.portao", "command" => "pulse" } ] }
      post "/api/v1/sites/#{site.id}/automations", params: { name: "Portão", definition: gate_def }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(json.dig("error", "code")).to eq("confirmation_required")
      post "/api/v1/sites/#{site.id}/automations", params: { name: "Portão", definition: gate_def, confirm_critical: true }, headers: headers, as: :json
      id = data["id"]
      operator = member("operator")
      post "/api/v1/automations/#{id}/run", params: { confirm_critical: true }, headers: auth_headers(operator), as: :json
      expect(response).to have_http_status(:forbidden)
      patch "/api/v1/automations/#{id}", params: { name: "x" }, headers: auth_headers(operator), as: :json
      expect(response).to have_http_status(:forbidden)
      get "/api/v1/automations/#{id}/runs", headers: auth_headers(operator)
      expect(response).to have_http_status(:ok)
    end

    it "modo single em andamento devolve 409" do
      post "/api/v1/sites/#{site.id}/automations", params: { name: "Espera", definition: { "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "wait", "for" => "5m" } ] } },
                                                   headers: headers, as: :json
      id = data["id"]
      post "/api/v1/automations/#{id}/run", headers: headers
      expect(data["status"]).to eq("waiting")
      post "/api/v1/automations/#{id}/run", headers: headers
      expect(response).to have_http_status(:conflict)
    end

    it "webhook: token gerado dispara com o JSON; desconhecido, desligado ou grande demais não" do
      fx = ha_fixture("webhook_ia_avisar")
      post "/api/v1/sites/#{site.id}/automations", params: { name: "IA avisa", mode: "queued", definition: fx["definition"], enabled: true }, headers: headers, as: :json
      id = data["id"]
      post "/api/v1/automations/#{id}/webhook", headers: headers
      url = data["url"]
      expect(url).to start_with("/api/v1/hooks/automations/")

      post url, params: { mensagem: "Deploy terminou", titulo: "CI" }, as: :json
      expect(response).to have_http_status(:accepted)
      expect(json.dig("data", "status")).to eq("done")
      expect(within(tenant) { Notification.last }).to have_attributes(title: "CI", body: "Deploy terminou")

      post "/api/v1/hooks/automations/nao-existe", params: { mensagem: "x" }, as: :json
      expect(response).to have_http_status(:not_found)
      post url, params: { mensagem: "x" * 11_000 }, as: :json
      expect(response).to have_http_status(:content_too_large)
      within(tenant) { Automation.find(id).update!(enabled: false) }
      post url, params: { mensagem: "x" }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
