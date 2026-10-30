require "rails_helper"

RSpec.describe "F8f: Automações e cenas (web e API)" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:area) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let!(:device) { within(tenant) { create(:device, site: site, name: "Quadro") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Luz", key: "sala.luz", value: false, area: area) } }
  let!(:motion) { within(tenant) { create(:point, device: device, name: "Movimento", key: "sala.movimento", capability: "motion", value: false) } }
  let!(:gate) { within(tenant) { create(:point, device: device, name: "Portão", key: "garagem.portao", capability: "gate", value: "closed", options: %w[open closed], risk: "critical") } }
  let(:on_motion) { { "triggers" => [ { "type" => "state", "point" => motion.id, "to" => true } ], "actions" => [ { "type" => "command", "point" => lamp.id, "command" => "on" } ] } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })
  def member(role) = create(:user, tenant: tenant, role: "member").tap { |u| within(tenant) { create(:site_membership, site: site, user: u, role: role) } }

  def automation(name, definition, **attrs)
    within(tenant) do
      a = site.automations.create!(name: name, **attrs)
      a.publish!(definition)
      a
    end
  end


  describe "seção com abas" do
    before { sign_in }

    it "mostra as abas, filtra, e liga/desliga/exclui em massa" do
      a1 = automation("Sala acende", on_motion, area: area, label_list: "iluminação, noite")
      a2 = automation("Outra", on_motion)
      within(tenant) { site.automations.create!(name: "Rascunho") }

      get "/locais/#{site.id}/automacoes"
      expect(response.body).to include("Automações e cenas", "Cenas", "Scripts", "Blueprints", "Regras simples", "Sala acende", "Marcar todas", "iluminação · noite")
      get "/locais/#{site.id}/automacoes", params: { q: "sala" }
      expect(response.body).to include("Sala acende").and(not_include_text("Outra"))
      get "/locais/#{site.id}/automacoes", params: { rotulo: "noite", area: area.id, estado: "desativadas" }
      expect(response.body).to include("Sala acende")
      get "/locais/#{site.id}/automacoes", params: { estado: "ativas" }
      expect(response.body).to include("Nenhuma automação com esses filtros")

      ids = within(tenant) { site.automations.pluck(:id) }
      post "/locais/#{site.id}/automacoes/lote", params: { ids: ids, op: "enable" }
      expect(flash[:notice]).to eq("2 automações ligadas (só as publicadas).")
      expect(within(tenant) { [ a1.reload.enabled, a2.reload.enabled ] }).to eq([ true, true ])
      post "/locais/#{site.id}/automacoes/lote", params: { ids: [ a1.id ], op: "disable" }
      expect(flash[:notice]).to eq("1 automação desligada.")
      post "/locais/#{site.id}/automacoes/lote", params: { ids: [], op: "delete" }
      expect(flash[:alert]).to include("Marque")
      post "/locais/#{site.id}/automacoes/lote", params: { ids: [ a2.id ], op: "zap" }
      expect(flash[:notice]).to eq("Nada feito.")
      post "/locais/#{site.id}/automacoes/lote", params: { ids: [ a2.id ], op: "delete" }
      expect(within(tenant) { Automation.exists?(a2.id) }).to be false
      expect(within(tenant) { Tagging.where(taggable_id: a1.id).count }).to eq(2)

      patch "/automacoes/#{a1.id}", params: { automation: { label_list: "noite" } }
      expect(within(tenant) { a1.reload.label_list }).to eq("noite")
      get "/locais/#{site.id}/automacao"
      expect(response).to redirect_to("/locais/#{site.id}/regras")
    end

    it "visitante vê as abas, mas não muda nada" do
      sign_in(member("guest"))
      automation("Sala acende", on_motion)
      get "/locais/#{site.id}/automacoes"
      expect(response.body).not_to include("Marcar todas")
      %w[cenas scripts blueprints regras].each do |tab|
        get "/locais/#{site.id}/#{tab}"
        expect(response).to have_http_status(:ok)
      end
      post "/locais/#{site.id}/automacoes/lote", params: { ids: [ within(tenant) { Automation.first.id } ], op: "delete" }
      expect(within(tenant) { Automation.count }).to eq(1)
    end
  end

  describe "scripts (web)" do
    before { sign_in }

    it "cria, monta campos e sequência, publica, executa com campos e vê o trace" do
      get "/locais/#{site.id}/scripts"
      expect(response.body).to include("Nenhum script neste local")
      get "/locais/#{site.id}/scripts/novo"
      expect(response.body).to include("Novo script")
      post "/locais/#{site.id}/scripts", params: { automation: { name: "" } }
      expect(response).to have_http_status(:unprocessable_content)
      post "/locais/#{site.id}/scripts", params: { automation: { name: "Acender cômodo", mode: "queued", icon: "light-bulb" } }
      s = within(tenant) { site.scripts.sole }
      expect(response).to redirect_to("/automacoes/#{s.id}/editar")

      get "/automacoes/#{s.id}/editar"
      expect(response.body).to include("Campos", "Sequência", "Adicionar campo").and(not_include_text("Só se"))

      patch "/automacoes/#{s.id}/campos", params: { op: "add", field: { name: "alvo", label: "Luz", type: "point", required: "1" } }
      patch "/automacoes/#{s.id}/campos", params: { op: "add", field: { name: "nivel", label: "Nível", type: "number", default: "3" } }
      patch "/automacoes/#{s.id}/campos", params: { op: "add", field: { name: "modo", type: "select", options: "a, b" } }
      patch "/automacoes/#{s.id}/campos", params: { op: "add", field: { name: "1ruim", type: "text" } }
      expect(flash[:alert]).to include("letras minúsculas")
      patch "/automacoes/#{s.id}/campos", params: { op: "add", field: { name: "num", type: "number", default: "x" } }
      expect(flash[:alert]).to include("Padrão inválido")
      patch "/automacoes/#{s.id}/campos", params: { op: "update", index: 2, field: { name: "modo", label: "Modo", type: "select", options: "a, b, c", default: "b" } }
      expect(within(tenant) { s.reload.fields }).to eq([
        { "name" => "alvo", "label" => "Luz", "type" => "point", "required" => true },
        { "name" => "nivel", "label" => "Nível", "type" => "number", "required" => false, "default" => 3 },
        { "name" => "modo", "label" => "Modo", "type" => "select", "required" => false, "default" => "b", "options" => %w[a b c] }
      ])
      patch "/automacoes/#{s.id}/campos", params: { op: "remove", index: 2 }
      expect(within(tenant) { s.reload.fields.size }).to eq(2)

      patch "/automacoes/#{s.id}/rascunho", params: { op: "add", target: "actions", type: "command" }
      patch "/automacoes/#{s.id}/rascunho", params: { op: "update", target: "actions.0", block: { point: "$alvo", command: "on" } }
      get "/automacoes/#{s.id}/editar"
      expect(response.body).to include("campo alvo")
      post "/automacoes/#{s.id}/publicar"
      expect(within(tenant) { s.reload.version }).to eq(1)
      expect(flash[:notice]).to eq("Versão 1 publicada.")

      get "/locais/#{site.id}/scripts"
      expect(response.body).to include("Acender cômodo", "2 campos", "Executar")
      get "/automacoes/#{s.id}/executar"
      expect(response.body).to include("Executar Acender cômodo", "Luz *", "Nível")
      post "/automacoes/#{s.id}/executar", params: { fields: { nivel: "4" } }
      expect(response).to redirect_to("/automacoes/#{s.id}/executar")
      expect(flash[:alert]).to include("Falta o campo Luz")
      post "/automacoes/#{s.id}/executar", params: { fields: { alvo: lamp.id } }
      run = within(tenant) { s.runs.sole }
      expect(response).to redirect_to("/execucoes/#{run.id}")
      expect(within(tenant) { lamp.reload.value }).to be true
      post "/automacoes/#{s.id}/executar", params: { fields: { alvo: gate.id } }
      expect(response).to have_http_status(:forbidden).or redirect_to("/")
      get "/execucoes/#{run.id}"
      expect(response.body).to include("Editar script", "Ligar Luz")
      get "/automacoes/#{s.id}/execucoes"
      expect(response.body).to include("Executar (")

      get "/automacoes/#{s.id}/simular"
      post "/automacoes/#{s.id}/simular", params: { publicada: "1" }
      expect(within(tenant) { s.runs.where(dry_run: true).count }).to eq(1)

      # O script como ponto: botão do painel e controle da página do ponto.
      point = within(tenant) { Scripts.point_for(s) }
      get "/pontos/#{point.id}"
      expect(response.body).to include("Acender cômodo")
      get "/locais/#{site.id}/dispositivos"
      expect(response.body).not_to include("Scripts")

      delete "/automacoes/#{s.id}"
      expect(response).to redirect_to("/locais/#{site.id}/scripts")
      expect(within(tenant) { Point.exists?(point.id) }).to be false
    end

    it "automação chama script pelo editor de blocos com os campos" do
      s = within(tenant) do
        x = site.scripts.create!(name: "Pisca", fields: [ { "name" => "alvo", "label" => "Luz", "type" => "point", "required" => true },
                                                       { "name" => "ativo", "label" => "Ativo", "type" => "boolean" } ])
        x.publish!({ "actions" => [ { "type" => "command", "point" => "$alvo", "command" => "toggle" } ] })
        x
      end
      a = within(tenant) { site.automations.create!(name: "Chama") }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "add", target: "actions", type: "script" }
      get "/automacoes/#{a.id}/editar", params: { b: "actions.0" }
      expect(response.body).to include("Escolha o script e salve o bloco")
      patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "actions.0", block: { script: s.id } }
      get "/automacoes/#{a.id}/editar", params: { b: "actions.0" }
      expect(response.body).to include("Luz *", "block[fields][alvo]")
      patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "actions.0", block: { script: s.id, fields: { alvo: "sala.luz", ativo: "true" } } }
      expect(within(tenant) { a.reload.draft["actions"] }).to eq([ { "type" => "script", "script" => s.id, "fields" => { "alvo" => lamp.id, "ativo" => true } } ])
      get "/automacoes/#{a.id}/editar"
      expect(response.body).to include("Pisca", "alvo = #{lamp.id}")
    end
  end

  describe "cenas (web)" do
    before { sign_in }

    it "captura o estado sem comandar, ajusta, salva e só aplica ao vivo quando pedido" do
      within(tenant) { lamp.report!(true) }
      level = within(tenant) { create(:point, device: device, name: "Dimmer", capability: "dimmer", value: 30) }
      get "/locais/#{site.id}/cenas"
      expect(response.body).to include("Nenhuma cena neste local")
      get "/locais/#{site.id}/cenas/novo"
      expect(response.body).to include("Capturar estado agora", "Modo ao vivo")

      post "/locais/#{site.id}/cenas", params: { capture: "1", capture_ids: [ lamp.id, level.id, motion.id ], scene: { name: "Cinema" } }
      expect(response.body).to include("Estado de 2 pontos capturado", "Agora: Ligado")
      expect(within(tenant) { [ Scene.count, Command.count ] }).to eq([ 0, 0 ])

      post "/locais/#{site.id}/cenas", params: { scene: { name: "Cinema", items: { "0" => { point_id: lamp.id, command: "off" }, "1" => { point_id: level.id, command: "set", value: "20" } } } }
      scene = within(tenant) { Scene.sole }
      expect(response).to redirect_to("/locais/#{site.id}/cenas")
      expect(scene.items).to eq([ { "point_id" => lamp.id, "command" => "off", "value" => nil }, { "point_id" => level.id, "command" => "set", "value" => "20" } ])
      expect(within(tenant) { [ lamp.reload.value, Command.count ] }).to eq([ true, 0 ])

      get "/cenas/#{scene.id}/editar"
      expect(response.body).to include("Estados da cena", "Agora: 30")
      patch "/cenas/#{scene.id}", params: { capture: "1", capture_ids: [ level.id ], scene: { name: "Cinema" } }
      expect(response.body).to include("Estado de 1 ponto capturado")
      patch "/cenas/#{scene.id}", params: { capture: "1", capture_ids: [], scene: { name: "Cinema" } }
      expect(response.body).to include("Nenhum ponto com valor")
      patch "/cenas/#{scene.id}", params: { scene: { name: "" } }
      expect(response).to have_http_status(:unprocessable_content)
      patch "/cenas/#{scene.id}", params: { live: "1", scene: { name: "Cinema 2" } }
      expect(response).to redirect_to("/cenas/#{scene.id}/editar")
      expect(flash[:notice]).to eq("Cena salva e aplicada ao vivo.")
      expect(within(tenant) { [ lamp.reload.value, level.reload.value ] }).to eq([ false, 20 ])

      get "/locais/#{site.id}/cenas", params: { q: "cine" }
      expect(response.body).to include("Cinema 2", "2 pontos", "Acionar")
      post "/locais/#{site.id}/cenas", params: { live: "1", scene: { name: "Portão", items: { "0" => { point_id: gate.id, command: "pulse" } } } }
      expect(within(tenant) { Scene.find_by(name: "Portão").present? }).to be true
    end
  end

  describe "blueprints (web)" do
    before { sign_in }

    it "lista os prontos, cria automação pelo formulário e mostra o vínculo" do
      get "/locais/#{site.id}/blueprints"
      expect(response.body).to include("Ligar luz por movimento", "Avisar quando sensor ficar aberto", "Desligar após X minutos", "Importar do HA")
      bp = within(tenant) { site.blueprints.find_by!(source: "builtin:luz_por_movimento") }
      get "/blueprints/#{bp.id}"
      expect(response.body).to include("Entradas", "Sensor de movimento", "padrão 2m")
      get "/blueprints/#{bp.id}/usar"
      expect(response.body).to include("Criar automação", "Escolha o ponto", "Só sensor de movimento ou sensor de abertura")
      post "/blueprints/#{bp.id}/usar", params: { name: "Sala", inputs: { sensor: lamp.id } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("não serve")
      post "/blueprints/#{bp.id}/usar", params: { name: "Sala por movimento", area_id: area.id, inputs: { sensor: motion.id, luz: lamp.id, tempo: "3m" } }
      a = within(tenant) { site.automations.sole }
      expect(response).to redirect_to("/automacoes/#{a.id}/editar")
      expect(flash[:notice]).to include("publicada, ainda desligada")
      expect(a).to have_attributes(blueprint_id: bp.id, area_id: area.id, blueprint_inputs: { "sensor" => motion.id, "luz" => lamp.id, "tempo" => "3m" })
      get "/automacoes/#{a.id}/editar"
      expect(response.body).to include("Criada de", "Sensor de movimento:", "Movimento")
      get "/blueprints/#{bp.id}"
      expect(response.body).to include("Sala por movimento")
      patch "/blueprints/#{bp.id}", params: { json: "{}" }
      expect(flash[:alert]).to include("pronto não se edita")
      delete "/blueprints/#{bp.id}"
      expect(flash[:alert]).to include("pronto não se exclui")
      post "/automacoes/#{a.id}/refazer"
      expect(flash[:notice]).to include("Rascunho refeito")
    end

    it "importa do HA (YAML e URL), mostra o não suportado, edita o JSON propagando e exclui" do
      get "/locais/#{site.id}/blueprints/importar"
      expect(response.body).to include("Importar do Home Assistant", "O que converte")
      post "/locais/#{site.id}/blueprints", params: { yaml: "blueprint: {}" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Não importou")
      post "/locais/#{site.id}/blueprints", params: { yaml: "blueprint: { name: X, domain: automation }\ntrigger: { platform: mqtt }\naction: []" }
      expect(response.body).to include("Nada que a DSL daqui rode", "nenhum gatilho e nenhuma ação", "Não suportado: gatilho mqtt")

      post "/locais/#{site.id}/blueprints", params: { yaml: file_fixture("ha_motion_light.yaml").read }
      bp = within(tenant) { site.blueprints.find_by!(source: "ha") }
      expect(response).to redirect_to("/blueprints/#{bp.id}")
      expect(flash[:notice]).to include("1 parte não suportada")
      get "/blueprints/#{bp.id}"
      expect(response.body).to include("Não suportado", "não suportado: ação wait_for_trigger", "Motion Sensor", "Salvar e propagar")

      stub_request(:get, "https://raw.githubusercontent.com/u/r/main/bp.yaml").to_return(body: file_fixture("ha_motion_light.yaml").read.sub("Motion-activated Light", "Via URL"))
      post "/locais/#{site.id}/blueprints", params: { url: "https://github.com/u/r/blob/main/bp.yaml" }
      expect(within(tenant) { site.blueprints.find_by(name: "Via URL").source_url }).to include("home-assistant/core")
      post "/locais/#{site.id}/blueprints", params: { url: "https://example.com/x.yaml" }
      expect(response.body).to include("Use um endereço https")

      post "/blueprints/#{bp.id}/usar", params: { name: "Do HA", inputs: { motion_entity: motion.id, light_target: lamp.id } }
      a = within(tenant) { site.automations.sole }
      data = JSON.parse(bp.reload.slice("name", "description", "mode", "inputs", "definition").to_json)
      data["definition"]["actions"][1]["for"] = 60
      patch "/blueprints/#{bp.id}", params: { json: data.to_json }
      expect(flash[:notice]).to eq("Versão 2: rascunho refeito em 1 automação.")
      expect(within(tenant) { a.reload.draft["actions"][1]["for"] }).to eq(60)
      get "/locais/#{site.id}/automacoes"
      expect(response.body).to include("Blueprint mudou")
      get "/automacoes/#{a.id}/editar"
      expect(response.body).to include("mudou (versão 2)", "Refazer rascunho")
      patch "/blueprints/#{bp.id}", params: { json: "[1]" }
      expect(flash[:alert]).to include("Não salvou")
      patch "/blueprints/#{bp.id}", params: { json: { "inputs" => [ { "key" => "X" } ] }.to_json }
      expect(flash[:alert]).to include("Não salvou")

      delete "/blueprints/#{bp.id}"
      expect(response).to redirect_to("/locais/#{site.id}/blueprints")
      expect(within(tenant) { a.reload.blueprint_id }).to be_nil
    end

    it "ponto crítico: operador não cria; técnico cria no rascunho (publicar pede confirmação)" do
      sign_in(member("technician"))
      bp = within(tenant) do
        site.blueprints.create!(name: "Portão", inputs: [ { "key" => "p", "label" => "P", "type" => "point" } ],
                                definition: { "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "command", "point" => { "!input" => "p" }, "command" => "pulse" } ] })
      end
      post "/blueprints/#{bp.id}/usar", params: { name: "Abre", inputs: { p: gate.id } }
      expect(within(tenant) { Automation.sole.published? }).to be false
      expect(flash[:notice]).to include("rascunho")
      sign_in(member("operator"))
      post "/blueprints/#{bp.id}/usar", params: { name: "Abre 2", inputs: { p: gate.id } }
      expect(within(tenant) { Automation.count }).to eq(1)
    end
  end

  describe "painel" do
    before { sign_in }

    it "tile liga/desliga mostra o switch; tile de script mostra Executar" do
      helper = within(tenant) do
        p = HelperTypes.build(site, HelperTypes::Toggle)
        HelperTypes.save(p, { "name" => "Férias" })
        p
      end
      s = within(tenant) { site.scripts.create!(name: "Boa noite").tap { |x| x.publish!({ "actions" => [ { "type" => "command", "point" => lamp.id, "command" => "off" } ] }) } }
      sp = within(tenant) { Scripts.point_for(s) }
      widgets = [ { "id" => "wh", "type" => "tile", "bind" => helper.id }, { "id" => "wl", "type" => "tile", "bind" => lamp.id }, { "id" => "ws", "type" => "tile", "bind" => sp.id } ]
      definition = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "Casa", "sections" => [ { "id" => "s", "widgets" => widgets } ] } ] }
      d = within(tenant) { site.dashboards.create!(name: "Casa", kind: "custom", definition: definition, version: 1) }
      get "/paineis/#{d.id}"
      expect(response.body.scan('class="ss-switch"').size).to eq(2)
      expect(response.body).to include('aria-label="Ligar Férias"', "Executar Boa noite")
      within(tenant) { lamp.report!(true) }
      post "/pontos/#{sp.id}/comando", params: { command: "run" }
      expect(within(tenant) { lamp.reload.value }).to be false
    end
  end

  describe "API" do
    let(:headers) { auth_headers(user) }
    let(:other) { within(tenant) { create(:site, name: "Loja") } }
    let(:key) { ->(scopes, sites = [ site.id ]) { { "X-Api-Key" => within(tenant) { ServiceApiKey.issue(user, name: "k", scopes: scopes, site_ids: sites).last } } } }

    it "CRUD de script com campos, executa com os campos (usuário e chave) e lista as execuções" do
      post "/api/v1/sites/#{site.id}/scripts", params: {
        name: "Acender", mode: "parallel", fields: [ { name: "alvo", label: "Luz", type: "point", required: true } ],
        definition: { actions: [ { type: "command", point: "$alvo", command: "on" } ] }
      }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      id = data["id"]
      expect(data).to include("kind" => "script", "version" => 1, "fields" => [ a_hash_including("name" => "alvo") ])
      get "/api/v1/sites/#{site.id}/scripts", headers: headers
      expect(data.pluck("name")).to eq([ "Acender" ])
      get "/api/v1/sites/#{site.id}/automations", headers: headers
      expect(data).to be_empty
      patch "/api/v1/scripts/#{id}", params: { name: "Acender luz", fields: [ { name: "alvo", label: "Luz", type: "point", required: true }, { name: "x", type: "cor" } ] }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      patch "/api/v1/scripts/#{id}", params: { name: "Acender luz" }, headers: headers, as: :json
      expect(data["name"]).to eq("Acender luz")

      post "/api/v1/scripts/#{id}/run", params: { fields: {} }, headers: headers, as: :json
      expect(json.dig("error", "code")).to eq("invalid_fields")
      post "/api/v1/scripts/#{id}/run", params: { fields: { alvo: gate.id } }, headers: headers, as: :json
      expect(json.dig("error", "code")).to eq("confirmation_required")
      post "/api/v1/scripts/#{id}/run", params: { fields: { alvo: "sala.luz" } }, headers: headers, as: :json
      expect(response).to have_http_status(:accepted)
      expect(data["status"]).to eq("done")
      expect(within(tenant) { lamp.reload.value }).to be true

      post "/api/v1/scripts/#{id}/run", params: { fields: { alvo: "sala.luz" } }, headers: key.call(%w[read]), as: :json
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/scripts/#{id}/run", params: { fields: { alvo: "sala.luz" } }, headers: key.call(%w[command], [ other.id ]), as: :json
      expect(response).to have_http_status(:not_found)
      post "/api/v1/scripts/#{id}/run", params: { fields: { alvo: "sala.luz" } }, headers: key.call(%w[command]), as: :json
      expect(response).to have_http_status(:accepted)
      get "/api/v1/scripts/#{id}/runs", headers: key.call(%w[read])
      expect(data.size).to eq(2)
      get "/api/v1/scripts/#{id}", headers: key.call(%w[read])
      expect(data["definition"]).to eq("actions" => [ { "type" => "command", "point" => "$alvo", "command" => "on" } ])
      delete "/api/v1/scripts/#{id}", headers: key.call(%w[write])
      expect(response).to have_http_status(:forbidden)

      within(tenant) { Automation.find(id).update!(draft: { "actions" => [] }) }
      within(tenant) { Automation.where(id: id).update_all(version: 0) } # rubocop:disable Rails/SkipsModelValidations
      post "/api/v1/scripts/#{id}/run", headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      delete "/api/v1/scripts/#{id}", headers: headers
      expect(response).to have_http_status(:no_content)
    end

    it "script em modo único já rodando: 409" do
      s = within(tenant) { site.scripts.create!(name: "Espera").tap { |x| x.publish!({ "actions" => [ { "type" => "wait", "for" => "5m" } ] }) } }
      post "/api/v1/scripts/#{s.id}/run", headers: headers, as: :json
      post "/api/v1/scripts/#{s.id}/run", headers: headers, as: :json
      expect(response).to have_http_status(:conflict)
    end

    it "aciona cena com a chave de integração" do
      scene = within(tenant) { site.scenes.create!(name: "Tudo", items: [ { "point_id" => lamp.id, "command" => "on" } ]) }
      get "/api/v1/sites/#{site.id}/scenes", headers: key.call(%w[read])
      expect(data.pluck("name")).to eq([ "Tudo" ])
      post "/api/v1/scenes/#{scene.id}/activate", headers: key.call(%w[read])
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/scenes/#{scene.id}/activate", headers: key.call(%w[command])
      expect(response).to have_http_status(:accepted)
      expect(within(tenant) { lamp.reload.value }).to be true
    end
  end

  def not_include_text(text) = satisfy("não conter #{text}") { |body| !body.include?(text) }
end
