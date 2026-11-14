require "rails_helper"

# pwa-ios (docs/pwa.md): o MA web como app no iPhone. Manifesto no idioma, service worker com versão e
# página sem conexão, área segura, instalar, push no iPhone, selo do ícone, sessão lembrada e o piso do Safari.
RSpec.describe "PWA no iPhone" do
  let(:user) { create(:user, name: "Dona") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Local") } }

  let(:iphone17) { "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1" }
  let(:iphone15) { "Mozilla/5.0 (iPhone; CPU iPhone OS 15_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6 Mobile/15E148 Safari/604.1" }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  it "manifesto: idioma de quem pede, atalhos, categorias e ícone maskable" do
    get "/manifest.json"
    expect(response.media_type).to eq("application/manifest+json")
    m = JSON.parse(response.body)
    expect(m).to include("display" => "standalone", "start_url" => "/", "lang" => "pt-BR")
    expect(m["categories"]).to include("utilities")
    expect(m["shortcuts"].map { |s| [ s["name"], s["url"] ] }).to eq([ [ "Câmeras", "/cameras" ], [ "Falar com a casa", "/?falar=1" ], [ "Notificações", "/notificacoes" ] ])
    expect(m["icons"].select { |i| i["purpose"] == "maskable" }.map { |i| i["sizes"] }).to contain_exactly("192x192", "512x512")

    get "/manifest.json", headers: { "Accept-Language" => "en-US,en;q=0.9" }
    expect(JSON.parse(response.body)).to include("lang" => "en")
    expect(JSON.parse(response.body)["shortcuts"].first["name"]).to eq("Cameras")
  end

  it "service worker: versão, página sem conexão guardada, selo e push; sem sessão" do
    get "/service-worker.js"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/javascript")
    expect(response.headers["Cache-Control"]).to include("no-cache")
    body = response.body
    version = body[/const VERSION = "(\h{12})"/, 1]
    expect(version).to be_present
    expect(body).to include(%(const OFFLINE_URL = "/sem-conexao"), "/icon-192.png", "tailwind", "setAppBadge", "clearAppBadge",
                            %(req.mode === "navigate"), "showNotification", "/push/resposta")
    # Nada da casa é guardado: o cache só recebe a lista fixa.
    expect(body.scan("cache.put").size).to eq(0)

    get "/service-worker.js", headers: { "Accept-Language" => "es" }
    expect(response.body[/const VERSION = "(\h{12})"/, 1]).not_to eq(version)
  end

  it "página sem conexão: pública, no idioma, sem guardar no cache do navegador" do
    get "/sem-conexao"
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body).to include("Sem conexão com a casa", "Tentar de novo", "viewport-fit=cover")
    expect(response.body).not_to include("csrf-token", "Dona")
    get "/sem-conexao", headers: { "Accept-Language" => "en" }
    expect(response.body).to include("No connection to the house")
  end

  it "telas: área segura, selo de não lidos, instalar (Aparência e Início) e push explicado no iPhone" do
    sign_in
    within(tenant) { 2.times { |i| Notifier.notify!(kind: "aviso", title: "A#{i}", push: false) } }
    get "/configuracoes/aparencia"
    expect(response.body).to include("viewport-fit=cover", %(<meta name="ma-unread" content="2">), 'id="instalar"', 'data-controller="pwa-install"',
                                     "Adicionar à Tela de Início", "ss-steps")
    get "/"
    expect(response.body).to include('data-pwa-install-mode-value="notice"', "Instale o app no iPhone", "#instalar")
    get "/configuracoes/aparelhos"
    expect(response.body).to include("ios_install", "ios_old")
    get "/entrar"
    expect(response).to redirect_to(root_path)
  end

  it "login: nota do Google para o app da Tela de Início" do
    allow(GoogleLogin).to receive(:enabled?).and_return(true)
    allow(GoogleLogin).to receive(:client_id).and_return("cliente.apps.googleusercontent.com")
    get "/entrar", headers: { "Host" => "casa.exemplo.com" }
    expect(response.body).to include('data-google-signin-target="standalone"', "passkey")
  end

  it "aparelho lembrado por 30 dias: sem a sessão (app do iPhone fechado) entra de novo; sair e trocar a senha derrubam" do
    sign_in
    cookie = Array(response.headers["Set-Cookie"]).join("\n")[/ma_remember=[^\n]*/]
    expect(cookie).to include("httponly")
    expect(Time.httpdate(cookie[/expires=([^;]+)/i, 1])).to be_within(1.hour).of(30.days.from_now)
    remember = cookies[:ma_remember]

    # iOS fechou o app: o cookie de sessão some, o de lembrar fica.
    cookies.delete("_minha_automacao_session")
    get "/configuracoes/aparencia"
    expect(response).to have_http_status(:ok)

    delete "/sair"
    expect(cookies[:ma_remember]).to be_blank
    get "/"
    expect(response).to redirect_to(%r{/entrar})

    # Cookie antigo depois da troca de senha não vale.
    user.update!(password: "outrasenha123")
    cookies["ma_remember"] = remember
    get "/"
    expect(response).to redirect_to(%r{/entrar})
  end

  it "Safari 16.4+ entra; mais velho leva o aviso do navegador" do
    get "/entrar", headers: { "User-Agent" => iphone17 }
    expect(response).to have_http_status(:ok)
    get "/entrar", headers: { "User-Agent" => iphone15, "Accept-Language" => "en" }
    expect(response).to have_http_status(:not_acceptable)
    expect(response.body).to include("Browser too old", "iOS 16.4")
  end

  it "Web Push leva os não lidos da pessoa para o selo do ícone (também no apagar)" do
    payloads = []
    allow(Push::Browser).to receive(:send_to) { |_sub, payload, **| payloads << JSON.parse(payload) and true }
    sub = PushSubscription.create!(user: user, endpoint: "https://push.exemplo.com/x", p256dh_key: "p", auth_key: "a")
    n = within(tenant) { Notifier.notify!(kind: "aviso", title: "Porta", push: false) }
    within(tenant) { Notifier.notify!(kind: "aviso", title: "Janela", push: false) }
    Push::Browser.deliver(user, Push::Message.new(n, user))
    Push::Browser.clear(user, "x")
    expect(payloads.map { |p| p["unread"] }).to eq([ 2, 2 ])
    expect(payloads.first).to include("title" => "Porta")
    expect(sub).to be_persisted
  end
end
