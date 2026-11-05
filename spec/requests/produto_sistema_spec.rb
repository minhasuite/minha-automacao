require "rails_helper"
require Rails.root.join("supervisor/server").to_s

# Produto: atualização com um clique (fonte de versões + supervisor +
# bin/ma-update) e acesso remoto por provedores.
RSpec.describe "Produto: sistema e acesso remoto" do
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

    it "a versão gravada na imagem (RELEASE_TAG) vale mais que a tag do .env (latest-stable)" do
      with_env("IMAGE" => "ghcr.io/minhasuite/minha-automacao:latest-stable", "RELEASE_TAG" => "v1.1.0") do
        expect(Updates.current_tag).to eq("v1.1.0")
        expect(Updates.available?({ "tag" => "v1.1.0" })).to be(false)
      end
      with_env("IMAGE" => "ghcr.io/minhasuite/minha-automacao:latest-stable", "RELEASE_TAG" => "") do
        expect(Updates.current_tag).to eq("latest-stable")
      end
    end

    it "acompanha o andamento pelo arquivo do bin/ma-update" do
      file = Rails.root.join("tmp/teste-update-status.json")
      with_env("UPDATE_STATUS_FILE" => file.to_s) do
        File.write(file, { state: "running", step: "pull", to: "x:v1.1.0" }.to_json)
        get "/configuracoes/sistema"
        expect(response.body).to include("Baixando a versão nova", "ss-reload", "ss-job")
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

  describe "canais e atualizar sozinho" do
    let(:settings_file) { Rails.root.join("tmp/teste-update-settings-#{SecureRandom.hex(4)}.json").to_s }
    let(:status_file) { Rails.root.join("tmp/teste-update-status-#{SecureRandom.hex(4)}.json").to_s }
    let(:releases_url) { "https://api.github.com/repos/minhasuite/minha-automacao/releases" }

    around do |ex|
      with_env("SUPERVISOR_URL" => base, "SUPERVISOR_TOKEN" => "x" * 40, "IMAGE" => "ghcr.io/minhasuite/minha-automacao:latest-stable",
               "RELEASE_TAG" => "v1.0.0", "UPDATE_SETTINGS_FILE" => settings_file, "UPDATE_STATUS_FILE" => status_file) { ex.run }
    ensure
      FileUtils.rm_f([ settings_file, status_file ])
    end

    before do
      Rails.cache.clear
      stub_request(:get, "#{releases_url}/latest")
        .to_return(status: 200, body: { tag_name: "v1.1.0", body: "estável", published_at: 3.days.ago.iso8601 }.to_json)
      stub_request(:get, "#{releases_url}?per_page=30").to_return(status: 200, body: [
        { tag_name: "v1.1.1-beta.10", prerelease: true, draft: false, published_at: 1.hour.ago.iso8601 },
        { tag_name: "v1.1.1-beta.9", prerelease: true, draft: false, published_at: 2.hours.ago.iso8601 },
        { tag_name: "v1.1.1-beta.11", prerelease: true, draft: true, published_at: nil },
        { tag_name: "v1.1.0", prerelease: false, draft: false, published_at: 3.days.ago.iso8601 }
      ].to_json)
    end

    it "compara versões: beta abaixo da estável do mesmo número, e a beta não volta para a estável dela" do
      expect(Updates.newer?("v1.1.0", "v1.0.0")).to be(true)
      expect(Updates.newer?("v1.1.1-beta.10", "v1.1.1-beta.9")).to be(true)
      expect(Updates.newer?("v1.1.1-beta.2", "v1.1.0")).to be(true)
      expect(Updates.newer?("v1.1.0", "v1.1.0-beta.5")).to be(false)
      expect(Updates.newer?("v1.1.1", "v1.1.0-beta.5")).to be(true)
      expect(Updates.newer?("v1.0.0", "v1.1.0")).to be(false)
      expect(Updates.newer?("v1.1.0", "sha-abc")).to be(true)
      expect(Updates.newer?("latest", "latest")).to be(false)
    end

    it "estável lê a última release; beta, a pré-release de número maior (sem rascunho)" do
      expect(Updates.latest(force: true)).to include("tag" => "v1.1.0", "prerelease" => false)
      Updates.configure!(channel: "beta", auto: "0", window_start: "3")
      expect(Updates.latest(force: true)).to include("tag" => "v1.1.1-beta.10", "prerelease" => true)
      expect { Updates.configure!(channel: "nightly", auto: "1", window_start: "3") }.to raise_error(Updates::Error, "Canal inválido.")
      expect { Updates.configure!(channel: "beta", auto: "1", window_start: "24") }.to raise_error(Updates::Error, "Horário inválido.")
    end

    it "o dono escolhe canal, janela e atualizar sozinho na tela; administrador não" do
      within(tenant) { create(:site) }
      sign_in
      get "/configuracoes/sistema"
      expect(response.body).to include("Canal", "Beta (novidades antes, menos testadas)", "03:00 às 05:00", "Atualizar sozinho")
      post "/configuracoes/sistema/atualizacao", params: { channel: "beta", auto: "1", window_start: "23" }
      expect(flash[:notice]).to eq("Atualização salva.")
      expect(Updates.settings).to include("channel" => "beta", "auto" => true, "window_start" => 23)
      expect(Updates.in_window?(Time.zone.parse("2026-11-04 00:30"))).to be(true)
      expect(Updates.in_window?(Time.zone.parse("2026-11-04 01:00"))).to be(false)

      admin = create(:user, tenant: tenant, role: "admin", email: "teste.adm2@ex.com")
      sign_in(admin)
      post "/configuracoes/sistema/atualizacao", params: { channel: "stable", auto: "0", window_start: "3" }
      expect(Updates.settings["channel"]).to eq("beta")
    end

    it "atualiza sozinho só ligado, na janela, com estável publicada há 2 dias e sem repetir a que falhou" do
      at = Time.zone.parse("2026-11-04 03:30")
      up = stub_request(:post, "#{base}/system/update").with(body: { image: "ghcr.io/minhasuite/minha-automacao:v1.1.0" }.to_json).to_return(status: 202, body: "{}")
      expect(Updates::Auto.start_if_due!(at)).to eq(:off)
      Updates.configure!(channel: "stable", auto: "1", window_start: "3")
      expect(Updates::Auto.start_if_due!(at + 3.hours)).to eq(:outside)
      File.write(status_file, { state: "running" }.to_json)
      expect(Updates::Auto.start_if_due!(at)).to eq(:running)
      File.write(status_file, {}.to_json)

      stub_request(:get, "#{releases_url}/latest").to_return(status: 200, body: { tag_name: "v1.1.0", published_at: (at - 1.day).iso8601 }.to_json)
      expect(Updates::Auto.start_if_due!(at)).to eq(:too_new)
      stub_request(:get, "#{releases_url}/latest").to_return(status: 200, body: { tag_name: "v1.1.0", published_at: (at - 3.days).iso8601 }.to_json)
      expect(Updates::Auto.start_if_due!(at)).to eq(:started)
      expect(up).to have_been_requested.once
      expect(Updates.settings["auto_started"]).to eq("v1.1.0")

      Updates.save_settings!("failed_tag" => "v1.1.0")
      expect(Updates::Auto.start_if_due!(at)).to eq(:failed_before)
      with_env("RELEASE_TAG" => "v1.1.0") { expect(Updates::Auto.start_if_due!(at)).to eq(:none) }

      Updates.save_settings!("failed_tag" => nil, "channel" => "beta")
      beta = stub_request(:post, "#{base}/system/update").with(body: { image: "ghcr.io/minhasuite/minha-automacao:v1.1.1-beta.10" }.to_json).to_return(status: 202, body: "{}")
      expect(Updates::Auto.start_if_due!(at)).to eq(:started) # beta não espera os 2 dias
      expect(beta).to have_been_requested
    end

    it "avisa o fim da atualização uma vez; a que voltou fica marcada para não repetir sozinha" do
      within(tenant) { create(:site) }
      File.write(status_file, { state: "rolled_back", step: "done", to: "x:v1.1.0", at: Time.current.utc.iso8601, message: "Voltou." }.to_json)
      expect { Updates::Auto.notify_result! }.to change { within(tenant) { Notification.where(kind: "sistema").count } }.by(1)
      expect(within(tenant) { Notification.where(kind: "sistema").last.title }).to eq("A atualização para v1.1.0 não deu certo e voltou para a versão anterior.")
      expect(Updates.settings["failed_tag"]).to eq("v1.1.0")
      expect { Updates::Auto.notify_result! }.not_to(change { within(tenant) { Notification.count } })

      File.write(status_file, { state: "done", to: "x:v1.0.5", at: 3.days.ago.utc.iso8601 }.to_json)
      expect { Updates::Auto.notify_result! }.not_to(change { within(tenant) { Notification.count } })
      expect(Updates.settings["notified_at"]).to be_present
      expect { UpdateAutoJob.perform_now }.not_to raise_error
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

    it "sem acesso ao registro, usa a imagem que já está na máquina; sem ela, não começa" do
      docker.add(labels: { "com.docker.compose.project" => "minha-automacao", "com.docker.compose.service" => "supervisor",
                           "com.docker.compose.project.working_dir" => "/opt/minha-automacao" })
      allow(docker).to receive(:pull).and_raise(Supervisor::Error, "denied")
      expect(req("POST", "/system/update", { image: "ghcr.io/minhasuite/minha-automacao:v1.1.0" }).first).to eq(202)

      docker.calls.clear
      allow(docker).to receive(:call).and_wrap_original do |m, method, path, **kw|
        path.start_with?("/images/") ? [ 404, {} ] : m.call(method, path, **kw)
      end
      docker.containers([ Supervisor::App::UPDATER_LABEL ]).each { |c| docker.inspect(c["Id"])["State"]["Running"] = false }
      expect(req("POST", "/system/update", { image: "ghcr.io/minhasuite/minha-automacao:v1.2.0" }).first).not_to eq(202)
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

    it "túnel manual aparece como configurado no servidor" do
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
end
