require "rails_helper"

# Central de notificações (web, API e app pelo AppScreen): filtros, marcar as
# filtradas como lidas, silenciar a origem por X horas, resumo do dia e
# as preferências (aba da central; antes Configurações → Notificações) e o sino do topo. Nada de push de verdade (FeatureFlag desligada).
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

    it "aviso rico na central do pacote: nível, silenciar e o Ciente do alerta aberto" do
      alert = within(tenant) do
        rule = AlertRule.create!(site: site, point: gate, name: "Portão aberto", operator: "eq", value: true, severity: "critical")
        Alert.create!(site: site, alert_rule: rule, point: gate, opened_at: 5.minutes.ago)
      end
      within(tenant) { Notifier.notify!(kind: "alerta", title: "Portão aberto há 5 min", push: false, data: { "alert_id" => alert.id, "point_id" => gate.id, "site_id" => site.id, "priority" => "critical" }) }
      get "/notificacoes"
      doc = Nokogiri::HTML(response.body)
      item = doc.css(".ss-ncenter-item").find { |li| li.text.include?("Portão aberto há 5 min") }
      expect(item["class"]).to include("is-critical", "is-unread")
      expect(item.at_css(".ss-ncenter-level").text).to include("Crítico")
      expect(item.at_css("form[action='/alertas/#{alert.id}/ciente?back=notificacoes']").text).to include("Ciente")
      expect(item.at_css("details.ss-ncenter-mute").text).to include("Silenciar")
      expect(doc.at_css(".ss-ncenter-head").text).to include("Marcar todas como lidas")

      post "/alertas/#{alert.id}/ciente", params: { back: "notificacoes" }
      expect(response).to redirect_to("/notificacoes")
      expect(within(tenant) { alert.reload.acked? }).to be true
      get "/notificacoes"
      expect(response.body).not_to include("/alertas/#{alert.id}/ciente")
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

    it "resumo do dia e preferências na central (fora de Configurações)" do
      get "/notificacoes/resumo"
      expect(response.body).to include("Resumo do dia", "2 avisos", 'href="/notificacoes/preferencias"')
      get "/configuracoes/notificacoes"
      expect(response).to redirect_to("/notificacoes/preferencias")
      get "/notificacoes/preferencias"
      expect(response.body).to include("Meu horário de silêncio", "Silêncio da casa", "Juntar avisos seguidos", 'aria-current="true" href="/notificacoes/preferencias"')
      expect(response.body).not_to include('href="/configuracoes/notificacoes"')
      get "/configuracoes/aparencia"
      expect(Nokogiri::HTML(response.body).css(".ss-subnav a").map(&:text).join(" ")).not_to include("Notificações")
      patch "/notificacoes/preferencias", params: { prefs: { quiet_enabled: "1", quiet_from: "22:00", quiet_to: "06:30", digest_enabled: "1", digest_at: "08:15",
                                                              mute_hours: "8", house_quiet_enabled: "1", house_quiet_from: "23:00", house_quiet_to: "06:00", merge_s: "60" } }
      expect(response).to redirect_to("/notificacoes/preferencias")
      prefs = Notifications.user_prefs(user.reload)
      expect(prefs["quiet"]).to eq("enabled" => true, "from" => "22:00", "to" => "06:30")
      expect(prefs["mute_hours"]).to eq(8)
      expect(Notifications.merge_window(tenant.reload)).to eq(60)
    end

    it "sino do topo: contador, últimos avisos, abrir marca como lido e leva ao destino, marcar todos fica na tela" do
      within(tenant) { aviso.update!(data: aviso.data.merge("url" => "/locais/#{site.id}")) }
      get "/locais"
      doc = Nokogiri::HTML(response.body)
      bell = doc.at_css("header .ss-bell")
      expect(bell["data-ss-bell-url-value"]).to eq("/notificacoes/contagem")
      expect(bell.at_css(".ss-bell-count").text).to eq("2")
      expect(bell.at_css("turbo-frame#avisos-list")["src"]).to eq("/notificacoes/recentes")
      expect(bell.at_css("a.ss-bell-foot")["href"]).to eq("/notificacoes")
      expect(bell.at_css(".ss-bell-head a.ss-icon-btn")["href"]).to eq("/notificacoes/preferencias")
      expect(doc.css(".ss-shell-nav a").map { |a| a["href"] }).not_to include("/notificacoes", "/perguntar")

      get "/notificacoes/contagem"
      expect(response.parsed_body).to eq("count" => 2)
      get "/notificacoes/recentes"
      frame = Nokogiri::HTML(response.body).at_css("turbo-frame#avisos-list")
      expect(frame.css("li").size).to eq(2)
      expect(frame.css(".ss-bell-item.is-unread").size).to eq(2)
      expect(frame.at_css("form[action='/notificacoes/#{aviso.id}/lida?open=1']")).to be_present

      patch "/notificacoes/#{aviso.id}/lida", params: { open: 1 }
      expect(response).to redirect_to("/locais/#{site.id}")
      patch "/notificacoes/#{sistema.id}/lida", params: { open: 1 }
      expect(response).to redirect_to("/notificacoes#notificacoes-item-#{sistema.id}")
      get "/notificacoes/contagem"
      expect(response.parsed_body).to eq("count" => 0)

      within(tenant) { Notifier.notify!(kind: "sistema", title: "Outro", push: false) }
      patch "/notificacoes/todas-lidas", params: { back: 1 }, headers: { "HTTP_REFERER" => "http://www.example.com/locais" }
      expect(response).to redirect_to("http://www.example.com/locais")
      expect(within(tenant) { Notification.for_user(user).unread.count }).to eq(0)
      get "/notificacoes/recentes"
      expect(response.body).not_to include("is-unread")
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
      %w[/notificacoes/preferencias /notificacoes/resumo /notificacoes].each do |path|
        get "/api/v1/screen", params: { path: path }, headers: auth_headers(user)
        expect(response).to have_http_status(:ok), path
        expect(data["page"]["blocks"]).to be_present
      end
    end
  end
end
