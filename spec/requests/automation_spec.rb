require "rails_helper"

RSpec.describe "Automação: web e API" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, latitude: -15.79, longitude: -47.88) } }
  let!(:device) { within(tenant) { create(:device, site: site, name: "Quadro") } }
  let!(:switch) { within(tenant) { create(:point, device: device, name: "Interruptor") } }
  let!(:light) { within(tenant) { create(:point, device: device, name: "Luz") } }
  let!(:door) { within(tenant) { create(:point, device: device, name: "Porta", capability: "contact", value: false) } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  describe "web" do
    before { sign_in }

    it "cria, edita, desativa e exclui cada primitiva a partir do local e do ponto" do
      get "/locais/#{site.id}/automacao"
      expect(response).to redirect_to("/locais/#{site.id}/regras")
      get "/locais/#{site.id}/regras"
      expect(response.body).to include("Regras simples", "Nenhuma agenda", "Nenhum espelhamento", "Nenhum aviso", "Nenhum alerta")

      back = "/pontos/#{switch.id}"
      get "/locais/#{site.id}/espelhamentos/novo", params: { point_id: switch.id, back: back }
      expect(response.body).to include("Quando este ponto mudar")
      post "/locais/#{site.id}/espelhamentos", params: { back: back, point_link: { source_point_id: switch.id, target_point_id: switch.id } }
      expect(response).to have_http_status(:unprocessable_content)
      post "/locais/#{site.id}/espelhamentos", params: { back: back, point_link: { source_point_id: switch.id, target_point_id: light.id, mode: "mirror", bidirectional: "1", enabled: "1" } }
      expect(response).to redirect_to(back)
      link = within(tenant) { PointLink.sole }

      post "/locais/#{site.id}/agendas", params: { schedule: { name: "Ligar 17h", kind: "time", time_of_day: "17:00", days: [ "", "1", "2" ], point_id: light.id, command: "on", enabled: "1" } }
      expect(response).to redirect_to("/locais/#{site.id}/regras")
      post "/locais/#{site.id}/avisos", params: { notify_rule: { point_id: door.id, to_value: "true", channels: [ "", "in_app", "push" ], enabled: "1" } }
      post "/locais/#{site.id}/regras-de-alerta", params: { alert_rule: {
        name: "Porta aberta", point_id: door.id, operator: "eq", value: "true", for_min: "5", severity: "warning", repeat_min: "160",
        auto_resolve: "1", enabled: "1", steps: { "0" => { wait_min: "0", channels: [ "in_app" ] }, "1" => { wait_min: "5", channels: %w[in_app push] }, "2" => { wait_min: "" } }
      } }
      rule = within(tenant) { AlertRule.sole }
      expect(rule).to have_attributes(for_s: 300, repeat_s: 9600, value: true)
      expect(rule.escalation.size).to eq(2)
      post "/locais/#{site.id}/cenas", params: { scene: { name: "Chegada", items: { "0" => { point_id: light.id, command: "on" }, "1" => { point_id: "" } } } }
      scene = within(tenant) { Scene.sole }
      expect(scene.items.size).to eq(1)

      get "/locais/#{site.id}/regras"
      expect(response.body).to include("Ligar 17h", "Interruptor → Luz", "nos dois sentidos", "Porta aberta", "por 5 min")
      get "/locais/#{site.id}/cenas"
      expect(response.body).to include("Chegada", "1 ponto")
      get "/pontos/#{switch.id}"
      expect(response.body).to include("Automação deste ponto", "Desligar sozinho", "Interruptor → Luz")
      get "/pontos/#{door.id}"
      expect(response.body).to include("quando ficar Aberto", "Porta aberta")

      get "/espelhamentos/#{link.id}/editar", params: { back: back }
      expect(response.body).to include("Salvar espelhamento")
      patch "/espelhamentos/#{link.id}", params: { back: back, point_link: { enabled: "false" } }
      expect(within(tenant) { link.reload.enabled }).to be false
      get "/agendas/#{within(tenant) { Schedule.sole.id }}/editar"
      expect(response.body).to include("Próxima vez")
      get "/regras-de-alerta/#{rule.id}/editar"
      expect(response.body).to include("Etapa 3")
      get "/cenas/#{scene.id}/editar"
      get "/avisos/#{within(tenant) { NotifyRule.sole.id }}/editar"
      expect(response).to have_http_status(:ok)
      patch "/regras-de-alerta/#{rule.id}", params: { alert_rule: { name: "" } }
      expect(response).to have_http_status(:unprocessable_content)

      post "/cenas/#{scene.id}/acionar", params: { back: "/locais/#{site.id}/automacao" }
      expect(flash[:notice]).to include("Chegada")
      expect(within(tenant) { light.reload.value }).to be true

      delete "/espelhamentos/#{link.id}"
      expect(within(tenant) { PointLink.count }).to eq(0)
    end

    it "alerta aberto aparece na central e some do aviso com Ciente" do
      within(tenant) { AlertRule.create!(point: door, name: "Porta aberta", value: true) }
      within(tenant) { door.report!(true) }
      get "/alertas"
      expect(response.body).to include("Porta aberta", "Ciente")
      alert = within(tenant) { Alert.sole }
      post "/alertas/#{alert.id}/ciente"
      expect(response).to redirect_to("/alertas")
      expect(within(tenant) { alert.reload.acked_by_id }).to eq(user.id)
      within(tenant) { door.report!(false) }
      get "/alertas"
      expect(response.body).to include("Resolvidos", "Nenhum alerta aberto")
    end

    it "visitante vê, mas não cadastra nem marca ciente" do
      guest = create(:user, tenant: tenant, role: "member")
      within(tenant) { create(:site_membership, site: site, user: guest, role: "guest") }
      within(tenant) { AlertRule.create!(point: door, name: "Porta aberta", value: false) }
      sign_in(guest)
      get "/locais/#{site.id}/regras"
      expect(response.body).not_to include("Novo")
      get "/locais/#{site.id}/cenas/novo"
      expect(response).to redirect_to("/")
      post "/alertas/#{within(tenant) { Alert.sole.id }}/ciente"
      expect(within(tenant) { Alert.sole.acked_at }).to be_nil
    end
  end

  describe "API" do
    let(:headers) { auth_headers(user) }

    it "CRUD das primitivas, acionar cena e ciente" do
      post "/api/v1/sites/#{site.id}/point_links", params: { source_point_id: switch.id, target_point_id: light.id, mode: "trigger" }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      link_id = data["id"]
      get "/api/v1/sites/#{site.id}/point_links", headers: headers
      expect(data.size).to eq(1)
      patch "/api/v1/point_links/#{link_id}", params: { enabled: false }, headers: headers, as: :json
      expect(data["enabled"]).to be false
      get "/api/v1/point_links/#{link_id}", headers: headers
      expect(data).not_to have_key("tenant_id")

      post "/api/v1/sites/#{site.id}/schedules", params: { name: "Pôr do sol", kind: "sunset", point_id: light.id, command: "on", days: [ 0, 6 ] }, headers: headers, as: :json
      expect(data["next_run_at"]).to be_present
      post "/api/v1/sites/#{site.id}/scenes", params: { name: "Tudo", items: [ { point_id: light.id, command: "on" }, { point_id: switch.id, command: "on" } ] }, headers: headers, as: :json
      scene_id = data["id"]
      post "/api/v1/scenes/#{scene_id}/activate", headers: headers
      expect(response).to have_http_status(:accepted)
      expect(data["commands"].size).to eq(2)
      expect(data["errors"]).to eq([])

      post "/api/v1/sites/#{site.id}/notify_rules", params: { point_id: door.id, to_value: true, channels: %w[push] }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      post "/api/v1/sites/#{site.id}/alert_rules", params: { name: "Porta", point_id: door.id, value: true,
                                                             escalation: [ { wait_s: 0, channels: %w[in_app] } ], repeat_s: 30 }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(json.dig("error", "details")).to have_key("repeat_s")
      post "/api/v1/sites/#{site.id}/alert_rules", params: { name: "Porta", point_id: door.id, value: true,
                                                             escalation: [ { wait_s: 0, channels: %w[in_app] } ] }, headers: headers, as: :json
      expect(response).to have_http_status(:created)

      post "/api/v1/points/#{door.id}/commands", params: { command: "on" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content) # sensor não recebe comando
      within(tenant) { door.report!(true) }
      get "/api/v1/alerts", headers: headers
      expect(data.sole).to include("name" => "Porta", "point_name" => "Porta", "level" => 1)
      post "/api/v1/alerts/#{data.sole['id']}/ack", headers: headers
      expect(data["acked_by_id"]).to eq(user.id)
      get "/api/v1/alerts/#{data['id']}", headers: headers
      expect(response).to have_http_status(:ok)
      within(tenant) { door.report!(false) }
      get "/api/v1/alerts", headers: headers
      expect(data).to eq([])
      get "/api/v1/alerts", params: { status: "all" }, headers: headers
      expect(data.size).to eq(1)

      delete "/api/v1/scenes/#{scene_id}", headers: headers
      expect(response).to have_http_status(:no_content)
    end

    it "outro local não serve e sem papel é 404" do
      other = within(tenant) { create(:site) }
      far = within(tenant) { create(:point, device: create(:device, site: other)) }
      post "/api/v1/sites/#{site.id}/point_links", params: { source_point_id: switch.id, target_point_id: far.id }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      stranger = create(:user)
      get "/api/v1/sites/#{site.id}/scenes", headers: auth_headers(stranger)
      expect(response).to have_http_status(:not_found)
    end
  end
end
