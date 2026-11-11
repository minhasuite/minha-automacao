require "rails_helper"

# Agilidade do editor de painel: JSON por widget e JSON Schema (P1.5), edição na
# própria tela (ideia 1), "Adicionar ao painel" (2), copiar/colar (4),
# desfazer/refazer e comparar (5), atalhos e Ctrl+K (7), prévia (24) e avisos ao
# publicar (25).
RSpec.describe "Editor de painel: agilidade" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:device) { within(tenant) { create(:device, site: site, name: "Teste Sala") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Luz", key: "teste.luz", value: true, reported_at: Time.current) } }
  let(:defn) do
    { "schema_version" => 1, "views" => [
      { "id" => "v", "title" => "Início", "sections" => [
        { "id" => "s1", "title" => "Um", "widgets" => [
          { "id" => "a", "type" => "tile", "bind" => lamp.id, "color" => "amber", "style_if" => [ { "tone" => "warn" } ] },
          { "id" => "b", "type" => "heading", "title" => "B" }
        ] },
        { "id" => "s2", "title" => "Dois", "widgets" => [ { "id" => "c", "type" => "heading", "title" => "C" } ] }
      ] },
      { "id" => "v2", "title" => "Outra", "sections" => [ { "id" => "s3", "title" => "Três", "widgets" => [] } ] }
    ] }
  end
  let!(:dashboard) { within(tenant) { site.dashboards.create!(name: "Teste", kind: "custom", definition: defn).tap { |d| d.publish!(defn) } } }

  before { post("/entrar", params: { email: user.email, password: "12345678" }) }

  def draft = within(tenant) { dashboard.reload.draft }
  def ids(defn, view = 0) = defn["views"][view]["sections"].map { |s| s["widgets"].pluck("id") }
  def patch_draft(params) = patch("/paineis/#{dashboard.id}/rascunho", params: { view_id: "v" }.merge(params))

  describe "P1.5: JSON de um widget e o JSON Schema" do
    it "mostra só o widget, salva no rascunho e recusa o que o Schema barra" do
      get "/paineis/#{dashboard.id}/w/a/json"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("widget_json", "bind", "/paineis/schema")
      expect(response.body).not_to include("&quot;id&quot;: &quot;a&quot;")

      patch "/paineis/#{dashboard.id}/w/a/json", params: { widget_json: { "type" => "heading", "title" => "Novo" }.to_json }
      expect(response).to redirect_to(%r{/paineis/#{dashboard.id}/editar})
      expect(draft["views"][0]["sections"][0]["widgets"][0]).to eq("id" => "a", "type" => "heading", "title" => "Novo")

      patch "/paineis/#{dashboard.id}/w/a/json", params: { widget_json: { "type" => "tile", "color" => "roxo", "style_if" => [ { "tone" => "x" } ] }.to_json }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("bind")
      patch "/paineis/#{dashboard.id}/w/a/json", params: { widget_json: "[1]" }
      expect(response).to have_http_status(:unprocessable_content)
      patch "/paineis/#{dashboard.id}/w/a/json", params: { widget_json: "{nada" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(draft["views"][0]["sections"][0]["widgets"][0]["title"]).to eq("Novo")

      get "/paineis/#{dashboard.id}/w/zzz/json"
      expect(response).to have_http_status(:not_found)
    end

    it "gera o JSON Schema do registro de widgets" do
      get "/paineis/schema.json"
      schema = response.parsed_body
      expect(schema["$schema"]).to include("2020-12")
      expect(schema.dig("$defs", "widget", "properties", "type", "enum")).to include("tile", "area_card", "stat")
      expect(schema.dig("$defs", "widget_area_card", "required")).to eq(%w[area])
      expect(schema.dig("$defs", "widget_stat", "properties", "aggregate", "enum")).to eq(Dashboards::Schema::AGGREGATES)
      expect(schema.dig("$defs", "widget_group", "properties", "binds", "maxItems")).to eq(8)
      expect(schema.dig("$defs", "widget_stack", "properties", "widgets")).to be_present
      expect(Dashboards::JsonSchema.for_type("nada")).to be_nil
    end
  end

  describe "ideia 1: editar na própria tela" do
    it "mostra o rascunho com arrastar e a gaveta; os ajustes voltam ao painel" do
      get "/paineis/#{dashboard.id}?editar=1"
      expect(response.body).to include('data-controller="layout-editor"', "dw-drawer-frame", "/paineis/#{dashboard.id}/w/a/ajustes", "Editor completo", 'data-controller="dashboard-keys"')

      get "/paineis/#{dashboard.id}/w/a/ajustes"
      expect(response.body).to include('id="dw-drawer-frame"', 'name="back"', 'value="painel"', 'data-turbo-frame="_top"')

      patch_draft(op: "update_widget", target: "a", back: "painel", widget: { type: "tile", label: "Lâmpada", bind: lamp.id })
      expect(response).to redirect_to("/paineis/#{dashboard.id}?editar=1&view=v")
      expect(draft["views"][0]["sections"][0]["widgets"][0]["label"]).to eq("Lâmpada")
      expect(dashboard.reload.definition).to eq(defn) # publicar continua explícito
    end

    it "o painel mostra o editar na tela para quem edita, não para o morador" do
      get "/paineis/#{dashboard.id}"
      expect(response.body).to include("editar=1", "Editar painel")
      other = create(:user, tenant: tenant, role: "member")
      within(tenant) { create(:site_membership, site: site, user: other, role: "resident") }
      delete "/sair"
      post("/entrar", params: { email: other.email, password: "12345678" })
      get "/paineis/#{dashboard.id}?editar=1"
      expect(response.body).not_to include("dw-drawer-frame")
      get "/paineis/#{dashboard.id}/w/a/ajustes"
      expect(response).not_to have_http_status(:ok)
    end
  end

  describe "ideia 2: adicionar ao painel" do
    it "do ponto, cria o widget pela capacidade na seção escolhida (rascunho)" do
      get "/pontos/#{lamp.id}"
      expect(response.body).to include("/paineis/adicionar?id=#{lamp.id}&amp;tipo=point")
      get "/paineis/adicionar", params: { tipo: "point", id: lamp.id }
      expect(response.body).to include("#{dashboard.id}:s2", "Outra · Três")

      post "/paineis/adicionar", params: { tipo: "point", id: lamp.id, place: "#{dashboard.id}:s3" }
      expect(response).to redirect_to(%r{/paineis/#{dashboard.id}/editar\?view=v2})
      w = draft["views"][1]["sections"][0]["widgets"].first
      expect(w).to include("type" => "tile", "bind" => lamp.id)
    end

    it "do aparelho, da cena e da automação/script" do
      other = within(tenant) { create(:point, device: device, name: "Temp", key: "teste.temp", capability: "measure") }
      scene = within(tenant) { site.scenes.create!(name: "Noite", items: [ { "point_id" => lamp.id, "command" => "off" } ]) }
      auto = within(tenant) { site.automations.create!(name: "Rega", kind: "automation").tap { |a| AutomationPoints.sync!(a) } }
      post "/paineis/adicionar", params: { tipo: "device", id: device.id, place: "#{dashboard.id}:s3" }
      post "/paineis/adicionar", params: { tipo: "scene", id: scene.id, place: "#{dashboard.id}:s3" }
      post "/paineis/adicionar", params: { tipo: "automation", id: auto.id, place: "#{dashboard.id}:s3" }
      list = draft["views"][1]["sections"][0]["widgets"]
      expect(list[0]).to include("type" => "group", "binds" => contain_exactly(lamp.id, other.id))
      expect(list[1]).to include("type" => "scene_bar", "scenes" => [ scene.id ])
      expect(list[2]).to include("type" => "tile", "bind" => within(tenant) { AutomationPoints.point_for(auto).id })

      post "/paineis/adicionar", params: { tipo: "point", id: lamp.id, place: "#{dashboard.id}:nada" }
      expect(response).to redirect_to(%r{/paineis/adicionar})
      get "/paineis/adicionar", params: { tipo: "planeta", id: lamp.id }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "ideia 4: copiar e colar" do
    it "copia o widget, cola em outra visão e em outro painel, e cola só o estilo" do
      post "/paineis/#{dashboard.id}/copiar", params: { kind: "widget", target: "a", view_id: "v" }
      expect(Dashboards::Clipboard.read(user.reload)).to include("kind" => "widget", "label" => "Luz")
      get "/paineis/#{dashboard.id}/editar"
      expect(response.body).to include("Na área de transferência", "Colar Luz aqui")

      patch_draft(op: "paste", target: "s3", view_id: "v2")
      pasted = draft["views"][1]["sections"][0]["widgets"].first
      expect(pasted).to include("type" => "tile", "bind" => lamp.id)
      expect(pasted["id"]).not_to eq("a")

      patch_draft(op: "paste_style", target: "b")
      expect(draft["views"][0]["sections"][0]["widgets"][1]).to include("color" => "amber", "style_if" => [ { "tone" => "warn" } ], "title" => "B")

      outro = within(tenant) { site.dashboards.create!(name: "Outro", kind: "custom", definition: defn).tap { |d| d.publish!(defn) } }
      post "/paineis/#{dashboard.id}/copiar", params: { kind: "section", target: "s1" }
      patch "/paineis/#{outro.id}/rascunho", params: { op: "paste", target: "v2", view_id: "v2" }
      copied = within(tenant) { outro.reload.draft }["views"][1]["sections"].last
      expect(copied["widgets"].size).to eq(2)
      expect(copied["id"]).not_to eq("s1")

      patch "/paineis/#{outro.id}/rascunho", params: { op: "paste_style", target: "a", view_id: "v" }
      expect(flash[:alert]).to be_present # a área tem uma seção, não um widget
    end

    it "nada para colar e área de outra empresa não valem" do
      user.update!(dashboard_prefs: { "clipboard" => { "kind" => "widget", "item" => { "type" => "heading" }, "tenant_id" => SecureRandom.uuid } })
      patch_draft(op: "paste", target: "s1")
      expect(flash[:alert]).to eq(I18n.t("dashboards.clip.empty"))
      post "/paineis/#{dashboard.id}/copiar", params: { kind: "view", target: "v" }
      expect(response).to have_http_status(:not_found)
      post "/paineis/#{dashboard.id}/copiar", params: { kind: "widget", target: "nada" }
      expect(flash[:alert]).to be_present
    end
  end

  describe "ideia 5: desfazer, refazer e comparar" do
    it "desfaz e refaz pela pilha do rascunho; publicar zera" do
      patch_draft(op: "duplicate", kind: "widget", target: "a")
      expect(ids(draft)[0].size).to eq(3)
      patch_draft(op: "remove", kind: "widget", target: "c")
      expect(ids(draft)[1]).to eq([])

      post "/paineis/#{dashboard.id}/desfazer"
      expect(ids(draft)[1]).to eq(%w[c])
      post "/paineis/#{dashboard.id}/desfazer"
      expect(draft).to be_nil # voltou a "sem rascunho"
      post "/paineis/#{dashboard.id}/desfazer"
      expect(flash[:alert]).to eq(I18n.t("dashboards.history.undo_empty"))
      post "/paineis/#{dashboard.id}/refazer"
      expect(ids(draft)[0].size).to eq(3)

      get "/paineis/#{dashboard.id}/editar"
      expect(response.body).to include("Desfazer: duplicar", "Refazer: remover")

      post "/paineis/#{dashboard.id}/publicar"
      expect(within(tenant) { DashboardDraftStep.where(dashboard_id: dashboard.id).count }).to eq(0)
    end

    it "guarda no máximo MAX passos" do
      stub_const("Dashboards::History::MAX", 2)
      3.times { |i| patch_draft(op: "update_section", target: "s1", title: "T#{i}") }
      expect(within(tenant) { DashboardDraftStep.where(dashboard_id: dashboard.id, kind: "undo").count }).to eq(2)
    end

    it "compara a publicada com o rascunho, por visão e widget" do
      patch_draft(op: "place", kind: "widget", target: "a", index: 0, parent: "s2")
      patch_draft(op: "update_section", target: "s1", title: "Um novo")
      patch "/paineis/#{dashboard.id}/w/c/json", params: { widget_json: { "type" => "heading", "title" => "C2" }.to_json }
      get "/paineis/#{dashboard.id}/comparar"
      body = response.body
      expect(body).to include("Rascunho", "Versão 1", "mudou de lugar", "Um novo", "C2")

      diff = Dashboards::Diff.call(defn, draft)
      expect(diff[0]["widgets"].find { |w| w["id"] == "a" }["status"]).to eq("moved")
      expect(diff[0]["widgets"].find { |w| w["id"] == "c" }["changes"]).to eq([ [ "title", "C", "C2" ] ])
      expect(diff[1]["status"]).to eq("same")
      expect(Dashboards::Diff.count(diff)).to eq(4) # a visão, a seção s1, "a" (mudou de lugar) e "c"; "b" não
      added = Dashboards::Diff.call({ "views" => [] }, defn)
      expect(added.map { |v| v["status"] }).to eq(%w[added added])

      get "/paineis/#{dashboard.id}/comparar", params: { a: "1", b: "1" }
      expect(response.body).to include("são iguais")
    end
  end

  describe "ideia 7: atalhos e Ctrl+K" do
    it "o editor tem os atalhos e as ações do painel na paleta" do
      get "/paineis/#{dashboard.id}/editar"
      expect(response.body).to include('data-controller="dashboard-keys"', "ss-shortcuts", 'data-dw-key="undo"', "Painel Teste", "nova_visao=1")
      get "/paineis/#{dashboard.id}/editar", params: { nova_visao: 1 }
      expect(response.body).to match(/id="dw-new-view"\s+open/)
    end

    it "a busca acha publicar, nova visão, voltar versão e duplicar widget" do
      get "/busca", params: { q: "publicar teste", paleta: 1 }
      expect(response.body).to include("Publicar painel Teste", "/paineis/#{dashboard.id}/revisar")
      get "/busca", params: { q: "teste", paleta: 1 }
      expect(response.body).not_to include("Publicar painel Teste") # só o nome = a fonte de painéis
      get "/busca", params: { q: "voltar versao", paleta: 1 }
      expect(response.body).to include("/paineis/#{dashboard.id}/comparar")
      get "/busca", params: { q: "duplicar luz", paleta: 1 }
      expect(response.body).to include("Duplicar Luz", "/paineis/#{dashboard.id}/rascunho", "op=duplicate")

      post "/paineis/#{dashboard.id}/rascunho", params: { op: "duplicate", kind: "widget", target: "a", view_id: "v" }
      expect(ids(draft)[0].size).to eq(3)
    end
  end

  describe "ideias 24 e 25: revisar, prévia e avisos" do
    it "mostra a prévia em iframes e os avisos com link para corrigir" do
      gone = within(tenant) { create(:device, site: site, name: "Velho", removed_at: Time.current) }
      old = within(tenant) { create(:point, device: gone, name: "Velha", key: "velho.x") }
      quiet = within(tenant) { create(:point, device: device, name: "Parado", key: "teste.parado", reported_at: 5.days.ago) }
      off = within(tenant) { create(:point, device: device, name: "Desligado", key: "teste.desl", disabled: true) }
      broken = defn.deep_dup
      broken["views"][1]["sections"][0]["widgets"] = [
        { "id" => "x1", "type" => "tile", "bind" => SecureRandom.uuid },
        { "id" => "x2", "type" => "group", "binds" => [ old.id, quiet.id, off.id ] },
        { "id" => "x3", "type" => "stat", "query" => { "capability" => "vacuum" }, "visible_if" => { "state" => { "point" => "nada.disso", "is" => true } } },
        { "id" => "x4", "type" => "area_card", "area" => SecureRandom.uuid }
      ]
      within(tenant) { dashboard.update!(draft: broken) }

      get "/paineis/#{dashboard.id}/revisar", params: { tema: "dark", view: "v2" }
      body = response.body
      expect(body).to include("embed=1", "tema=dark", "<iframe", "390 px", "768 px", "1280 px")
      expect(body).to include("Ponto sumiu", "Aparelho removido", "Sem sinal", "Ponto desativado", "Consulta vazia", "Área sumiu")
      expect(body).to include("/paineis/#{dashboard.id}/editar?view=v2&amp;w=x2#x2")
      expect(body).to include("Publicar mesmo assim?")

      kinds = within(tenant) { Dashboards::Lint.call(site, broken) }.map { |w| w["kind"] }
      expect(kinds).to include("missing_point", "device_removed", "silent", "point_disabled", "empty_query", "missing_area")
      expect(kinds.count("missing_point")).to eq(2) # o bind e o ponto do visible_if

      get "/paineis/#{dashboard.id}", params: { rascunho: 1, embed: 1, tema: "dark", view: "v2" }
      expect(response.body).to include('data-theme="dark"')
      expect(response.body).not_to include("ss-app-shell", 'id="palette"')
    end

    it "sem aviso, diz que está tudo em ordem; cena que sumiu avisa" do
      get "/paineis/#{dashboard.id}/revisar"
      expect(response.body).to include("Nenhum aviso")
      bad = within(tenant) { Dashboards::Lint.call(site, { "views" => [ { "id" => "v", "sections" => [ { "id" => "s", "widgets" => [ { "id" => "q", "type" => "scene_bar", "scenes" => [ SecureRandom.uuid ] } ] } ] } ] }) }
      expect(bad.map { |w| w["kind"] }).to eq(%w[missing_scene])
    end

    it "o editor manda publicar pela revisão" do
      patch_draft(op: "update_section", target: "s1", title: "X")
      get "/paineis/#{dashboard.id}/editar"
      expect(response.body).to include("/paineis/#{dashboard.id}/revisar", "Revisar e publicar")
    end
  end
end
