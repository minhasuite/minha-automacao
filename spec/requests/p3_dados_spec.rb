require "rails_helper"

# P3 (personalização por dado): telas da web, o mesmo pelo app (AppScreen) e a API.
RSpec.describe "P3: personalização por dado (web, app e API)" do
  let(:user) { create(:user, role: "owner") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Lâmpada", driver: "virtual") } }
  let!(:luz) { within(tenant) { create(:point, site: site, device: device, name: "Luz", key: "sala.luz", value: false, writable: true) } }
  let!(:sensor) { within(tenant) { create(:point, site: site, device: device, name: "Sensor porta", capability: "contact", quality: "unavailable") } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })
  def screen(path) = get("/api/v1/screen", params: { path: path }, headers: auth_headers(user))
  def submit(path, fields, method: "post") = post("/api/v1/screen", params: { path: path, method: method, fields: fields }, headers: auth_headers(user), as: :json)
  def page = response.parsed_body.dig("data", "page")
  def walk(blocks, &) = blocks.each { |b| yield b; walk(Array(b["c"]), &); Array(b["rows"]).flatten.each { |c| walk(Array(c), &) } if b["rows"] }
  def all_blocks = [].tap { |out| walk(page["blocks"] + page["actions"].to_a) { |b| out << b } }

  describe "Saúde: verificações personalizadas (web)" do
    before { sign_in }

    it "cria com prévia, aparece na Saúde, edita e remove" do
      get "/configuracoes/saude"
      expect(response.body).to include("/configuracoes/saude/verificacoes", "Verificações personalizadas")
      get "/configuracoes/saude/verificacoes"
      expect(response.body).to include("Nenhuma verificação personalizada")
      get "/configuracoes/saude/verificacoes/nova"
      expect(response.body).to include("custom_health_check[query]", "Ver prévia")

      form = { site_id: site.id, name: "", query: "quality=unavailable", severity: "error", message: "{{ count }} sem sinal", enabled: "1" }
      post "/configuracoes/saude/verificacoes", params: { custom_health_check: form, preview: "1" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("1 sem sinal", "Com erro")
      expect(within(tenant) { CustomHealthCheck.count }).to eq(0)

      post "/configuracoes/saude/verificacoes", params: { custom_health_check: form.merge(query: "cor=azul", name: "x"), preview: "1" }
      expect(response.body).to include("cor")

      post "/configuracoes/saude/verificacoes", params: { custom_health_check: form.merge(name: "Sem sinal") }
      expect(response).to redirect_to("/configuracoes/saude/verificacoes")
      check = within(tenant) { CustomHealthCheck.last }
      get "/configuracoes/saude"
      expect(response.body).to include("Sem sinal (Casa)", "1 sem sinal")
      get "/configuracoes/saude/verificacoes"
      expect(response.body).to include("Sem sinal", "quality=unavailable")

      get "/configuracoes/saude/verificacoes/#{check.id}/editar"
      expect(response.body).to include("Sem sinal")
      patch "/configuracoes/saude/verificacoes/#{check.id}", params: { custom_health_check: { expression: "count > 5", query: "quality=unavailable" }, preview: "1" }
      expect(response.body).to include("Ok")
      patch "/configuracoes/saude/verificacoes/#{check.id}", params: { custom_health_check: { name: "" } }
      expect(response).to have_http_status(:unprocessable_content)
      patch "/configuracoes/saude/verificacoes/#{check.id}", params: { custom_health_check: { severity: "warn" } }
      expect(within(tenant) { check.reload.severity }).to eq("warn")
      delete "/configuracoes/saude/verificacoes/#{check.id}"
      expect(within(tenant) { CustomHealthCheck.count }).to eq(0)
    end

    it "membro não vê" do
      member = create(:user, tenant: tenant, role: "member")
      sign_in(member)
      get "/configuracoes/saude/verificacoes"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "Avisos e alertas: Liquid com prévia (web)" do
    before { sign_in }

    it "aviso: prévia sem salvar, salva e edita" do
      get "/locais/#{site.id}/avisos/novo"
      expect(response.body).to include("notify_rule[message]", "Ver prévia", "points_where")
      fields = { point_id: luz.id, message: "{{ trigger.point }} ficou {{ trigger.text }} em {{ site.name }}", channels: [ "in_app" ], enabled: "1" }
      post "/locais/#{site.id}/avisos", params: { notify_rule: fields, preview: "1" }
      expect(response.body).to include("Luz ficou Desligado em Casa")
      expect(within(tenant) { NotifyRule.count }).to eq(0)
      post "/locais/#{site.id}/avisos", params: { notify_rule: fields.merge(message: "{{ abre") }
      expect(response).to have_http_status(:unprocessable_content)
      post "/locais/#{site.id}/avisos", params: { notify_rule: fields }
      rule = within(tenant) { NotifyRule.last }
      expect(rule.message).to include("trigger.point")
      patch "/avisos/#{rule.id}", params: { notify_rule: { message: "{{ \"x\" | calc }}" }, preview: "1" }
      expect(response.body).to include("x")
      expect(within(tenant) { rule.reload.message }).to include("trigger.point")
    end

    it "alerta: texto do aviso com prévia" do
      fields = { name: "Luz acesa", point_id: luz.id, operator: "eq", value: "true", for_min: "0", severity: "warning", message: "{{ trigger.alert }} há {{ trigger.minutes }} min" }
      post "/locais/#{site.id}/regras-de-alerta", params: { alert_rule: fields, preview: "1" }
      expect(response.body).to include("Luz acesa há 0 min")
      post "/locais/#{site.id}/regras-de-alerta", params: { alert_rule: fields }
      expect(within(tenant) { AlertRule.last.message }).to include("trigger.alert")
    end
  end

  describe "Voz da casa (web)" do
    let!(:scene) { within(tenant) { site.scenes.create!(name: "Cinema", items: [ { "point_id" => luz.id, "command" => "on" } ]) } }

    before { sign_in }

    it "aba Da casa: cria, edita e remove frase e resposta" do
      get "/locais/#{site.id}/assistente", params: { aba: "personalizadas" }
      expect(response.body).to include("intent[sentences_text]", "response[ref]", "Cinema")

      post "/locais/#{site.id}/assistente/intencoes", params: { intent: { name: "Filme", language: "", sentences_text: "hora do filme", target: "scene:#{scene.id}", response: "", enabled: "1" } }
      expect(flash[:notice]).to be_present
      ci = within(tenant) { AssistCustomIntent.last }
      expect(ci).to have_attributes(sentences: [ "hora do filme" ], scene_id: scene.id, language: nil)
      patch "/locais/#{site.id}/assistente/intencoes/#{ci.id}", params: { intent: { sentences_text: "[abre" } }
      expect(flash[:alert]).to be_present
      patch "/locais/#{site.id}/assistente/intencoes/#{ci.id}", params: { intent: { name: "Filme 2" } }
      expect(within(tenant) { ci.reload.name }).to eq("Filme 2")

      post "/locais/#{site.id}/assistente/respostas", params: { response: { ref: "turn_on.done", language: "pt-BR", text: "Pronto, {names}." } }
      cr = within(tenant) { AssistCustomResponse.last }
      expect(cr.ref).to eq("turn_on.done")
      patch "/locais/#{site.id}/assistente/respostas/#{cr.id}", params: { response: { text: "Ok {names}." } }
      expect(within(tenant) { cr.reload.text }).to eq("Ok {names}.")
      get "/locais/#{site.id}/assistente", params: { aba: "personalizadas" }
      expect(response.body).to include("Filme 2", "turn_on.done")

      post "/assistente", params: { site_id: site.id, text: "hora do filme" }
      expect(within(tenant) { luz.reload.value }).to be true

      delete "/locais/#{site.id}/assistente/intencoes/#{ci.id}"
      delete "/locais/#{site.id}/assistente/respostas/#{cr.id}"
      expect(within(tenant) { [ AssistCustomIntent.count, AssistCustomResponse.count ] }).to eq([ 0, 0 ])
    end
  end

  describe "pelo app (AppScreen)" do
    it "abre as telas novas e envia o formulário" do
      [ "/configuracoes/saude/verificacoes", "/configuracoes/saude/verificacoes/nova", "/locais/#{site.id}/assistente?aba=personalizadas",
        "/locais/#{site.id}/avisos/novo" ].each do |p|
        screen(p)
        expect(response).to have_http_status(:ok), p
      end
      screen("/configuracoes/saude/verificacoes/nova")
      names = all_blocks.select { |b| b["t"] == "field" }.map { |b| b["name"] }
      expect(names).to include("custom_health_check[query]", "custom_health_check[expression]", "custom_health_check[message]")
      expect(all_blocks.select { |b| b["t"] == "submit" }.map { |b| b["name"] }).to include("preview")

      submit("/configuracoes/saude/verificacoes", [ [ "custom_health_check[site_id]", site.id ], [ "custom_health_check[name]", "Pelo app" ],
                                                    [ "custom_health_check[query]", "quality=unavailable" ], [ "custom_health_check[severity]", "warn" ] ])
      expect(within(tenant) { CustomHealthCheck.pluck(:name) }).to eq([ "Pelo app" ])
    end
  end

  describe "API" do
    let(:h) { auth_headers(user) }

    it "Saúde e verificações personalizadas" do
      post "/api/v1/health_checks", params: { site_id: site.id, name: "Sem sinal", query: "quality=unavailable", severity: "error" }, headers: h
      expect(response).to have_http_status(:created)
      id = data["id"]
      get "/api/v1/health_checks", headers: h
      expect(data.map { |c| c["name"] }).to eq([ "Sem sinal" ])
      get "/api/v1/health_checks/#{id}", headers: h
      expect(data["result"]).to include("status" => "error")
      patch "/api/v1/health_checks/#{id}", params: { severity: "warn" }, headers: h
      expect(data["severity"]).to eq("warn")
      post "/api/v1/health_checks/preview", params: { site_id: site.id, query: "quality=unavailable", message: "{{ count }}" }, headers: h
      expect(data).to include("problem" => true, "count" => 1, "detail" => "1", "status" => "warn")
      post "/api/v1/health_checks/preview", params: { site_id: site.id, query: "cor=x" }, headers: h
      expect(response).to have_http_status(:unprocessable_content)
      post "/api/v1/health_checks/preview", params: { site_id: site.id, expression: "nao_existe > 1" }, headers: h
      expect(response).to have_http_status(:unprocessable_content)
      get "/api/v1/health", headers: h
      expect(data.map { |r| r["key"] }).to include("custom")
      expect(data.find { |r| r["key"] == "custom" }["items"].first["title"]).to eq("Sem sinal (Casa)")
      delete "/api/v1/health_checks/#{id}", headers: h
      expect(response).to have_http_status(:no_content)

      member = create(:user, tenant: tenant, role: "member")
      get "/api/v1/health", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end

    it "prévia do texto, alerta com mensagem e voz da casa" do
      post "/api/v1/sites/#{site.id}/message_preview", params: { template: "{{ trigger.point }}: {{ trigger.text }}", point_id: luz.id }, headers: h
      expect(data).to eq("text" => "Luz: Desligado")
      post "/api/v1/sites/#{site.id}/message_preview", params: { template: "{{ abre" }, headers: h
      expect(response).to have_http_status(:unprocessable_content)

      post "/api/v1/sites/#{site.id}/alert_rules", params: { name: "A", point_id: luz.id, operator: "eq", value: true, message: "{{ trigger.alert }}" }, headers: h, as: :json
      expect(data["message"]).to eq("{{ trigger.alert }}")

      scene = within(tenant) { site.scenes.create!(name: "Cinema", items: [ { "point_id" => luz.id, "command" => "on" } ]) }
      post "/api/v1/sites/#{site.id}/assist/intents", params: { name: "Filme", sentences: [ "hora do filme" ], target: "scene:#{scene.id}" }, headers: h, as: :json
      expect(response).to have_http_status(:created)
      expect(data).to include("target" => "scene:#{scene.id}", "sentences" => [ "hora do filme" ])
      get "/api/v1/sites/#{site.id}/assist/intents", headers: h
      expect(data.size).to eq(1)
      post "/api/v1/sites/#{site.id}/assist/responses", params: { ref: "scene.done", text: "Cena {name} no ar." }, headers: h, as: :json
      expect(data).to include("ref" => "scene.done")
      get "/api/v1/sites/#{site.id}/assist/responses", headers: h
      expect(json.dig("meta", "choices").map { |c| c["ref"] }).to include("scene.done", "custom.done")
      post "/api/v1/sites/#{site.id}/assist", params: { text: "ativar a cena cinema" }, headers: h
      expect(response.body).to include("Cena Cinema no ar.")
    end
  end
end
