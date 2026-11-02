require "rails_helper"
require Rails.root.join("supervisor/server").to_s

# Produto: atualização com um clique (fonte de versões + supervisor +
# bin/ma-update), acesso remoto por provedores e planos com limites.
RSpec.describe "Produto: sistema, acesso remoto e plano" do
  let(:owner) { create(:user, email: "teste.dono@ex.com") }
  let(:tenant) { owner.tenant }
  let(:base) { "http://supervisor:8099" }

  def sign_in(u = owner) = post("/entrar", params: { email: u.email, password: "12345678" })

  def with_env(vars)
    old = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  describe "atualização" do
    around { |ex| with_env("SUPERVISOR_URL" => base, "SUPERVISOR_TOKEN" => "x" * 40, "IMAGE" => "ghcr.io/minhasuite/minha-automacao:v1.0.0") { ex.run } }

    before do
      Rails.cache.delete(Updates::CACHE_KEY)
      stub_request(:get, "https://api.github.com/repos/minhasuite/minha-automacao/releases/latest")
        .to_return(status: 200, body: { tag_name: "v1.1.0", name: "1.1", body: "Teste: novidades", html_url: "https://x", published_at: "2026-11-01T10:00:00Z" }.to_json)
      within(tenant) { create(:site) }
      sign_in
    end

    it "mostra a versão nova e atualiza com um clique (dono), sem aceitar outra imagem" do
      get "/configuracoes/sistema"
      expect(response.body).to include("v1.0.0", "v1.1.0", "Atualização disponível", "Atualizar agora", "Teste: novidades")
      up = stub_request(:post, "#{base}/system/update").with(body: { image: "ghcr.io/minhasuite/minha-automacao:v1.1.0" }.to_json).to_return(status: 202, body: "{}")
      post "/configuracoes/sistema/atualizar", params: { tag: "v1.1.0" }
      expect(up).to have_been_requested
      expect(flash[:notice]).to eq("Atualização começou. Acompanhe aqui.")
      post "/configuracoes/sistema/atualizar", params: { tag: "../evil:latest" }
      expect(flash[:alert]).to eq("Versão inválida.")

      member = create(:user, tenant: tenant, role: "admin", email: "teste.adm@ex.com")
      sign_in(member)
      post "/configuracoes/sistema/atualizar", params: { tag: "v1.1.0" }
      expect(up).to have_been_requested.once
    end

    it "acompanha o andamento pelo arquivo do bin/ma-update" do
      file = Rails.root.join("tmp/teste-update-status.json")
      with_env("UPDATE_STATUS_FILE" => file.to_s) do
        File.write(file, { state: "running", step: "pull", to: "x:v1.1.0" }.to_json)
        get "/configuracoes/sistema"
        expect(response.body).to include("Baixando a versão nova", "reload", "up-spin")
        File.write(file, { state: "rolled_back", step: "done", to: "x:v1.1.0", message: "" }.to_json)
        get "/configuracoes/sistema"
        expect(response.body).to include("A atualização para v1.1.0 não deu certo")
      ensure
        FileUtils.rm_f(file)
      end
    end

    it "sem release publicada ou com o GitHub fora, a tela continua" do
      stub_request(:get, %r{api.github.com}).to_return(status: 404)
      expect(Updates.latest(force: true)).to be_nil
      stub_request(:get, %r{api.github.com}).to_return(status: 500)
      expect(Updates.latest(force: true)).to be_nil
      get "/configuracoes/sistema"
      expect(response.body).to include("Não deu para consultar agora.")
    end
  end

  describe "supervisor: /system" do
    before { allow(Supervisor).to receive(:log) }

    let(:docker) { FakeDocker.new }
    let(:app) { Supervisor::App.new(docker: docker, token: "t" * 40, network: "ma-apps", project: "minha-automacao") }

    def req(method, path, body = nil)
      env = Rack::MockRequest.env_for(path, method: method, input: body&.to_json, "HTTP_AUTHORIZATION" => "Bearer #{'t' * 40}")
      status, _h, out = app.call(env)
      [ status, JSON.parse(out.join) ]
    end

    it "atualiza num container à parte com a pasta do compose; só imagem do produto e uma por vez" do
      docker.add(labels: { "com.docker.compose.project" => "minha-automacao", "com.docker.compose.service" => "supervisor",
                           "com.docker.compose.project.working_dir" => "/opt/minha-automacao" })
      expect(req("POST", "/system/update", { image: "docker.io/outro:latest" }).first).to eq(422)
      status, body = req("POST", "/system/update", { image: "ghcr.io/minhasuite/minha-automacao:v1.1.0" })
      expect([ status, body.dig("data", "image") ]).to eq([ 202, "ghcr.io/minhasuite/minha-automacao:v1.1.0" ])
      expect(docker.pulled).to eq([ "ghcr.io/minhasuite/minha-automacao:v1.1.0", Supervisor::App::UPDATER_IMAGE ])
      create = docker.calls.find { |c| c[1] == "/containers/create" }[2]
      expect(create["HostConfig"]["Binds"]).to include("/opt/minha-automacao:/opt/minha-automacao", "/var/run/docker.sock:/var/run/docker.sock")
      expect(create["Env"]).to include("NEW_IMAGE=ghcr.io/minhasuite/minha-automacao:v1.1.0")
      expect(create["Cmd"].last).to include("pg_dump", "rolled_back", "healthy")
      expect(req("POST", "/system/update", { image: "ghcr.io/minhasuite/minha-automacao:v1.1.0" }).first).to eq(409)
      expect(req("GET", "/system/nada").first).to eq(404)
    end

    it "liga e desliga o túnel; o manual do compose tem prioridade" do
      expect(req("POST", "/system/remote", { provider: "x", token: "a" * 40 }).first).to eq(422)
      expect(req("POST", "/system/remote", { provider: "cloudflare", token: "curto" }).first).to eq(422)
      status, body = req("POST", "/system/remote", { provider: "cloudflare", token: "a" * 40 })
      expect([ status, body.dig("data", "provider"), body.dig("data", "state") ]).to eq([ 200, "cloudflare", "running" ])
      create = docker.calls.select { |c| c[1] == "/containers/create" }.last[2]
      expect(create["Env"]).to eq([ "TUNNEL_TOKEN=#{'a' * 40}" ])
      expect(create["HostConfig"]["NetworkMode"]).to eq("minha-automacao_default")
      expect(req("DELETE", "/system/remote").last.dig("data", "provider")).to be_nil

      docker.add(labels: { "com.docker.compose.project" => "minha-automacao", "com.docker.compose.service" => "cloudflared" })
      expect(req("GET", "/system/remote").last.dig("data", "manual")).to be(true)
      expect(req("POST", "/system/remote", { provider: "cloudflare", token: "a" * 40 }).first).to eq(409)
    end
  end

  describe "acesso remoto" do
    around { |ex| with_env("SUPERVISOR_URL" => base, "SUPERVISOR_TOKEN" => "x" * 40) { ex.run } }

    before { sign_in }

    it "liga com o token cifrado, mostra o estado e desliga" do
      stub_request(:get, "#{base}/system/remote").to_return(body: { data: { manual: false, provider: "cloudflare", state: "running" } }.to_json)
      on = stub_request(:post, "#{base}/system/remote").with(body: { provider: "cloudflare", token: "tok-#{'a' * 30}" }.to_json).to_return(body: "{}")
      patch "/configuracoes/acesso-remoto", params: { provider: "cloudflare", remote: { token: "tok-#{'a' * 30}", url: "https://teste.exemplo.com" } }
      expect(on).to have_been_requested
      s = tenant.reload.settings["remote_access"]
      expect(s).to include("provider" => "cloudflare", "enabled" => true, "url" => "https://teste.exemplo.com")
      expect(s["secret"]).not_to include("tok-")
      expect(RemoteAccess.unseal(s["secret"])).to eq("tok-#{'a' * 30}")

      get "/configuracoes/acesso-remoto"
      expect(response.body).to include("Ligado", "https://teste.exemplo.com", "Cloudflare Tunnel", "deixe vazio para manter o atual", "Acesso MinhaSuite")
      expect(response.body).not_to include("tok-")

      patch "/configuracoes/acesso-remoto", params: { provider: "cloudflare", remote: { token: "", url: "http://inseguro" } }
      expect(flash[:alert]).to eq("O endereço público precisa começar com https://.")
      off = stub_request(:delete, "#{base}/system/remote").to_return(body: "{}")
      delete "/configuracoes/acesso-remoto"
      expect(off).to have_been_requested
      expect(tenant.reload.settings.dig("remote_access", "enabled")).to be(false)
    end

    it "plano sem acesso remoto não liga; túnel manual aparece como configurado no servidor" do
      Licensing.set!(tenant, "free")
      patch "/configuracoes/acesso-remoto", params: { provider: "cloudflare", remote: { token: "a" * 40 } }
      expect(flash[:alert]).to include("acesso remoto")
      stub_request(:get, "#{base}/system/remote").to_return(body: { data: { manual: true } }.to_json)
      get "/configuracoes/acesso-remoto"
      expect(response.body).to include("Configurado no servidor", "configurado à mão")
    end

    it "provedor novo entra pelo registro (plugin falso)" do
      fake = Class.new(RemoteAccess::Provider) do
        describe key: "teste_relay", icon: "sparkles"
        def self.label = "Teste Relay"
        def self.description = "Relay de teste"
        def self.enable!(tenant, _form) = RemoteAccess.save!(tenant, "provider" => key, "enabled" => true, "url" => "https://teste.relay")
      end
      stub_const("RemoteAccess::TesteRelay", fake)
      stub_const("RemoteAccess::PROVIDERS", %w[CloudflareTunnel TesteRelay])
      stub_request(:get, "#{base}/system/remote").to_return(body: { data: {} }.to_json)
      get "/configuracoes/acesso-remoto"
      expect(response.body).to include("Teste Relay", "Relay de teste")
      patch "/configuracoes/acesso-remoto", params: { provider: "teste_relay" }
      expect(tenant.reload.settings["remote_access"]).to include("provider" => "teste_relay", "url" => "https://teste.relay")
    end
  end

  describe "plano" do
    before { sign_in }

    it "o dono atual é pro ilimitado; free limita aparelhos e pessoas" do
      site = within(tenant) { create(:site) }
      expect(Licensing.plan(tenant)).to eq("pro")
      get "/configuracoes/plano"
      expect(response.body).to include("Seu plano", "Pro", "Ilimitado", "Comparar planos", "Grátis", "Plus")

      Licensing.set!(tenant, "free", limits: { "devices" => 2 })
      within(tenant) { 2.times { |i| create(:device, site: site, name: "Teste #{i}") } }
      extra = within(tenant) { build(:device, site: site, name: "Teste 3") }
      expect(extra).not_to be_valid
      expect(extra.errors[:base].first).to include("aparelhos")
      get "/configuracoes/plano"
      expect(response.body).to include("2 <span", "/ 2", "Não incluído", "30 dias")

      2.times { |i| create(:user, tenant: tenant, email: "teste.p#{i}@ex.com") }
      expect(build(:user, tenant: tenant)).not_to be_valid
      expect { Licensing.check!(tenant, "users") }.to raise_error(Licensing::Exceeded)
      expect(Licensing.allowed?(tenant, "cloud_backup")).to be(false)
    end

    it "limite novo entra pelo registro (plugin falso)" do
      fake = Class.new(Licensing::Limit) do
        describe key: "teste_cenas", kind: :count
        def self.usage(_tenant) = 4
      end
      stub_const("Licensing::TesteCenas", fake)
      stub_const("Licensing::LIMITS", Licensing::LIMITS + %w[TesteCenas])
      Licensing.set!(tenant, "plus", limits: { "teste_cenas" => 5 })
      expect(Licensing.allowed?(tenant, "teste_cenas")).to be(true)
      expect(Licensing.allowed?(tenant, "teste_cenas", adding: 2)).to be(false)
      expect(Licensing::PAYMENT_PROVIDERS).to eq([])
    end
  end
end
