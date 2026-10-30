require "rails_helper"

# Lote 1: PWA, Meus aparelhos, resposta dos botões (in-app e service worker),
# imagem assinada e o editor da ação Avisar.
RSpec.describe "Lote 1: telas de push e avisos" do
  let(:user) { create(:user, name: "Dona") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Local") } }
  let(:buttons) { [ { "id" => "sim", "title" => "Sim" }, { "id" => "nao", "title" => "Não" } ] }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  def aviso(**data)
    within(tenant) { Notifier.notify!(kind: "automacao", title: "Pergunta", push: false, data: { "site_id" => site.id, "actions" => buttons }.merge(data)) }
  end

  it "PWA: manifesto, service worker, ícones e cabeçalho" do
    get "/manifest.json"
    expect(JSON.parse(response.body)).to include("display" => "standalone", "start_url" => "/")
    get "/service-worker.js"
    expect(response.body).to include("showNotification", "/push/resposta")
    get "/entrar"
    expect(response.body).to include('rel="manifest"', "apple-touch-icon")
  end

  describe "Meus aparelhos" do
    before { sign_in }

    it "inscreve, lista, renomeia ao inscrever de novo, remove e manda teste" do
      get "/configuracoes/aparelhos"
      expect(response.body).to include("Este aparelho", "Nenhum aparelho ainda", "iOS 16.4")
      body = { endpoint: "https://push.exemplo.com/abc", keys: { p256dh: "p", auth: "a" }, name: "" }
      post "/configuracoes/aparelhos", params: body, as: :json, headers: { "User-Agent" => "Mozilla/5.0 (Linux; Android 14) Chrome/130" }
      expect(response).to have_http_status(:created)
      expect(json["name"]).to eq("Chrome no Android")
      post "/configuracoes/aparelhos", params: body.merge(name: "Meu celular"), as: :json
      sub = user.push_subscriptions.sole
      expect(sub.name).to eq("Meu celular")
      post "/configuracoes/aparelhos", params: { endpoint: "http://inseguro", keys: { p256dh: "p", auth: "a" } }, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      within(tenant) { user.device_tokens.create!(token: "t1", platform: "android") }
      get "/configuracoes/aparelhos"
      expect(response.body).to include("Meu celular", "App Minha Automação (Android)")

      post "/configuracoes/aparelhos/teste"
      expect(flash[:alert]).to include("faltam as chaves VAPID")
      allow(Push).to receive(:transports).and_return([ Push::Browser ])
      expect { post "/configuracoes/aparelhos/teste" }.to have_enqueued_job(SendPushJob)
      expect(flash[:notice]).to include("Teste enviado")

      delete "/configuracoes/aparelhos/#{sub.id}"
      expect(user.push_subscriptions.count).to eq(0)
      get "/configuracoes/conta"
      expect(response.body).to include("Gerenciar aparelhos")
    end
  end

  describe "resposta ao aviso" do
    it "in-app: botões, imagem e link; a primeira resposta vale" do
      sign_in
      n = aviso("url" => "https://exemplo.com/painel", "image_url" => "https://img.exemplo.com/a.jpg")
      get "/notificacoes"
      expect(response.body).to include("Sim", "Não", "https://img.exemplo.com/a.jpg", "Abrir")
      patch "/notificacoes/#{n.id}/responder", params: { action_id: "talvez" }
      expect(flash[:alert]).to eq("Botão inválido.")
      patch "/notificacoes/#{n.id}/responder", params: { action_id: "sim" }
      expect(flash[:notice]).to eq("Resposta enviada: Sim.")
      patch "/notificacoes/#{n.id}/responder", params: { action_id: "nao" }
      expect(flash[:alert]).to eq("Este aviso já foi respondido.")
      get "/notificacoes"
      expect(response.body).to include("Respondido: Sim (Dona)")
    end

    it "service worker: só com o token da pessoa, uma vez" do
      n = aviso
      token = within(tenant) { n.action_token(user) }
      post "/push/resposta", params: { token: "falso", action_id: "sim" }, as: :json
      expect(response).to have_http_status(:not_found)
      post "/push/resposta", params: { token: token, action_id: "x" }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      post "/push/resposta", params: { token: token, action_id: "sim" }, as: :json
      expect(response).to have_http_status(:no_content)
      post "/push/resposta", params: { token: token, action_id: "nao" }, as: :json
      expect(response).to have_http_status(:conflict)
      expect(within(tenant) { n.reload.response }).to include("action" => "sim", "user_id" => user.id)
    end

    it "imagem por id assinado; sem assinatura ou vencida, 404" do
      n = aviso
      within(tenant) { n.image.attach(io: StringIO.new("\xFF\xD8x".b), filename: "q.jpg", content_type: "image/jpeg") }
      url = within(tenant) { n.image_url }
      get url
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/jpeg")
      get "/push/imagem", params: { t: "x" }
      expect(response).to have_http_status(:not_found)
      travel(Notification::IMAGE_TTL + 1.minute) { get url }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "editor da ação Avisar e trace" do
    before { sign_in }

    it "salva botões, destinatário, câmera, link e prioridade pelo formulário" do
      cam = within(tenant) { create(:point, device: create(:device, site: site, driver: "go2rtc", name: "Câmera"), capability: "stream", name: "Entrada") }
      a = within(tenant) { Automation.create!(site: site, name: "Teste Lote1 aviso", mode: "single") }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "add", target: "actions", type: "notify" }
      patch "/automacoes/#{a.id}/rascunho", params: { op: "update", target: "actions.0",
                                                     block: { title: "Oi", buttons: "sim: Sim\nNão quero\n", to: "role:resident", camera: cam.id,
                                                              url: "/paineis", priority: "critical", ttl: "1h", sticky: "1", continue_on_error: "1", channels: [ "", "in_app" ] } }
      node = within(tenant) { a.reload.draft["actions"][0] }
      expect(node).to include("buttons" => [ { "id" => "sim", "title" => "Sim" }, { "id" => "nao_quero", "title" => "Não quero" } ],
                              "to" => "role:resident", "camera" => cam.id, "priority" => "critical", "sticky" => true, "continue_on_error" => true)
      get "/automacoes/#{a.id}/editar"
      expect(response.body).to include("Botões (até 3", "sim: Sim", "Câmera: Entrada", "Quem é morador ou mais no local", "Seguir se der erro")
      patch "/automacoes/#{a.id}/rascunho", params: { op: "add", target: "actions", type: "calendar_events" }
      get "/automacoes/#{a.id}/editar"
      expect(response.body).to include("Devolve na variável", "Guardar a resposta em")
    end

    it "trace mostra o erro tolerado" do
      a = within(tenant) do
        x = Automation.create!(site: site, name: "Teste Lote1 erro", mode: "single")
        x.publish!({ "triggers" => [ { "type" => "manual" } ],
                     "actions" => [ { "type" => "http", "method" => "GET", "url" => "https://api.exemplo.com/f", "continue_on_error" => true } ] })
        x
      end
      stub_request(:get, "https://api.exemplo.com/f").to_return(status: 503)
      run = within(tenant) { a.fire!({ "type" => "manual", "title" => "Manual" }) }
      get "/execucoes/#{run.id}"
      expect(response.body).to include("erro tolerado", "api.exemplo.com respondeu 503.", "text-warn")
    end
  end
end
