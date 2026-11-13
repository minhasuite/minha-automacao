require "rails_helper"

# Central de notificações (web, API e app pelo AppScreen): filtros, marcar as
# filtradas como lidas, silenciar a origem por X horas, resumo do dia e
# Configurações → Notificações. Nada de push de verdade (FeatureFlag desligada).
RSpec.describe "Central de notificações com menos ruído" do
  let(:user) { create(:user, name: "Dona") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:area) { within(tenant) { Area.create!(site: site, name: "Garagem") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Virtual", driver: "virtual") } }
  let(:gate) { within(tenant) { create(:point, device: device, site: site, key: "garagem.portao", name: "Portão", capability: "contact", data_type: "bool", value: false, area: area) } }
  let!(:aviso) { within(tenant) { Notifier.notify!(kind: "aviso", title: "Portão: Aberto", push: false, data: { "point_id" => gate.id, "site_id" => site.id, "priority" => "high" }) } }
  let!(:sistema) { within(tenant) { Notifier.notify!(kind: "sistema", title: "Atualização pronta", push: false) } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  describe "web" do
    before { sign_in }

    it "filtra, marca as filtradas como lidas e mostra nível" do
      get "/notificacoes", params: { kind: "aviso" }
      expect(response.body).to include("Portão: Aberto", "Importante", "Silenciar")
      expect(response.body).not_to include("Atualização pronta")
      get "/notificacoes", params: { area_id: area.id }
      expect(response.body).to include("Portão: Aberto")
      get "/notificacoes", params: { kind: "convite" }
      expect(response.body).to include("Nada com estes filtros")
      patch "/notificacoes/todas-lidas", params: { kind: "aviso" }
      expect(aviso.reload.read_at).to be_present
      expect(sistema.reload.read_at).to be_nil
    end

    it "silencia pelo aviso, lista e reativa" do
      patch "/notificacoes/#{aviso.id}/silenciar", params: { hours: 4 }
      expect(flash[:notice]).to include("Portão silenciado até")
      get "/notificacoes"
      expect(response.body).to include("Silenciados agora", "Reativar")
      delete "/notificacoes/silencios", params: { key: "point:#{gate.id}" }
      expect(Notifications.mute_list(user.reload)).to be_empty
      patch "/notificacoes/#{sistema.id}/silenciar"
      expect(flash[:alert]).to include("não tem automação nem ponto")
    end

    it "resumo do dia e Configurações → Notificações" do
      get "/notificacoes/resumo"
      expect(response.body).to include("Resumo do dia", "2 avisos")
      get "/configuracoes/notificacoes"
      expect(response.body).to include("Meu horário de silêncio", "Silêncio da casa", "Juntar avisos seguidos")
      patch "/configuracoes/notificacoes", params: { prefs: { quiet_enabled: "1", quiet_from: "22:00", quiet_to: "06:30", digest_enabled: "1", digest_at: "08:15",
                                                              mute_hours: "8", house_quiet_enabled: "1", house_quiet_from: "23:00", house_quiet_to: "06:00", merge_s: "60" } }
      expect(response).to redirect_to("/configuracoes/notificacoes")
      prefs = Notifications.user_prefs(user.reload)
      expect(prefs["quiet"]).to eq("enabled" => true, "from" => "22:00", "to" => "06:30")
      expect(prefs["mute_hours"]).to eq(8)
      expect(Notifications.merge_window(tenant.reload)).to eq(60)
    end

    it "nível e janela na regra de aviso" do
      get "/locais/#{site.id}/avisos/novo"
      expect(response.body).to include("notify_rule[priority]", "notify_rule[merge_s]")
    end
  end

  describe "API" do
    let(:headers) { auth_headers(user) }

    it "lista com filtros e opções, silencia, reativa, resumo e preferências" do
      get "/api/v1/notifications", params: { kind: "aviso" }, headers: headers
      expect(data.map { |n| n["title"] }).to eq([ "Portão: Aberto" ])
      expect(data.first).to include("level" => "high", "count" => 1, "mute_key" => "point:#{gate.id}")
      expect(json["meta"]["filters"]["kinds"]).to include({ "value" => "aviso", "label" => "Avisos de ponto" })
      expect(json["meta"]["filters"]["areas"]).to eq([ { "value" => area.id, "label" => "Garagem" } ])

      post "/api/v1/notifications/#{aviso.id}/mute", params: { hours: 2 }, headers: headers
      expect(data).to include("key" => "point:#{gate.id}", "label" => "Portão")
      post "/api/v1/notifications/#{sistema.id}/mute", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      get "/api/v1/notifications", headers: headers
      expect(json["meta"]["mutes"].sole["key"]).to eq("point:#{gate.id}")
      delete "/api/v1/notifications/mutes", params: { key: "point:#{gate.id}" }, headers: headers
      expect(data["mutes"]).to eq([])

      patch "/api/v1/notifications/read", params: { kind: "sistema" }, headers: headers
      expect(data["marked"]).to eq(1)

      get "/api/v1/notifications/digest", headers: headers
      expect(data["sections"].map { |s| s["key"] }).to include("notices")

      patch "/api/v1/notifications/preferences", params: { digest_enabled: true, digest_at: "07:00" }, headers: headers
      expect(data["digest"]).to eq("enabled" => true, "at" => "07:00")
      get "/api/v1/notifications/preferences", headers: headers
      expect(data).to include("house", "mute_hours")
    end

    it "NotifyRule aceita nível e janela" do
      post "/api/v1/sites/#{site.id}/notify_rules", params: { point_id: gate.id, channels: %w[in_app], priority: "critical", merge_s: 0 }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(data).to include("priority" => "critical", "merge_s" => 0)
    end
  end

  describe "app (AppScreen)" do
    it "as telas novas abrem transcodificadas" do
      %w[/configuracoes/notificacoes /notificacoes/resumo /notificacoes].each do |path|
        get "/api/v1/screen", params: { path: path }, headers: auth_headers(user)
        expect(response).to have_http_status(:ok), path
        expect(data["page"]["blocks"]).to be_present
      end
    end
  end
end
