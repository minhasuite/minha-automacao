require "rails_helper"

# Integrador (docs/PROPOSTA-integrador.md, 24/11/2026): a instalação manda o resumo (só contagens e situações) e a
# central mostra, avisa e segura versão. Nada sai para a rede (WebMock); o estado vai para arquivos temporários.
RSpec.describe "Integrador" do
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }
  let(:tmp) { Pathname(Dir.mktmpdir) }

  around do |ex|
    old = ENV.to_h.slice("INTEGRATOR_HUB", "INTEGRATOR_URL", "INTEGRATOR_TOKEN")
    ex.run
  ensure
    %w[INTEGRATOR_HUB INTEGRATOR_URL INTEGRATOR_TOKEN].each { |k| ENV[k] = old[k] }
  end

  before do
    allow(Integrator).to receive(:state_path).and_return(tmp.join("integrator.json"))
    allow(ServerVitals).to receive(:path).and_return(tmp.join("vitals.json"))
    allow(ServerVitals).to receive(:temperature).and_return(62)
  end

  after { FileUtils.rm_rf(tmp) }

  def sign_in(u = owner) = post("/entrar", params: { email: u.email, password: "12345678" })
  def titles = within(tenant) { Notification.where(kind: "sistema").order(:created_at).pluck(:title) }

  describe "instalação: o resumo" do
    it "traz versão, servidor, backup, saúde e contagens da casa, sem nome de aparelho nem de pessoa" do
      within(tenant) do
        site = create(:site, name: "Casa da Eva")
        dev = create(:device, site: site, name: "Echo Suíte Eva")
        create(:point, device: dev, name: "Luz do quarto da Eva", quality: "unavailable")
      end
      r = Integrator::Report.build
      expect(r.keys).to include("version", "server", "backup", "health", "house")
      expect(r["server"]).to include("temp" => 62, "online" => true)
      expect(r["house"]).to include("devices" => 1, "points_unavailable" => 1)
      expect(r["health"]["server"]).to include("status" => "ok")
      expect(r.to_json).not_to include("Eva") # LGPD: só contagens e situações
    end

    it "manda com o token e guarda a versão liberada pela central; falha fica no estado" do
      ENV["INTEGRATOR_URL"] = "https://central.exemplo.com"
      ENV["INTEGRATOR_TOKEN"] = "ma_inst_abc"
      req = stub_request(:post, "https://central.exemplo.com/api/v1/integrador/resumo")
              .with(headers: { "Authorization" => "Bearer ma_inst_abc" }).to_return(status: 200, body: { max_version: "v0.9.3" }.to_json)
      IntegratorReportJob.perform_now
      expect(req).to have_been_requested
      expect(Integrator.max_version).to eq("v0.9.3")

      stub_request(:post, "https://central.exemplo.com/api/v1/integrador/resumo").to_raise(Errno::ECONNREFUSED)
      expect { IntegratorReportJob.perform_now }.not_to raise_error
      expect(Integrator.state["error"]).to be_present
      expect(Integrator.max_version).to eq("v0.9.3") # a última resposta continua valendo
    end

    it "o freio: a atualização sozinha não passa da versão liberada" do
      allow(Integrator).to receive(:max_version).and_return("v0.9.3")
      expect(Updates::Auto.held?({ "tag" => "v0.9.4" })).to be(true)
      expect(Updates::Auto.held?({ "tag" => "v0.9.3" })).to be(false)
      allow(Integrator).to receive(:max_version).and_return(nil)
      expect(Updates::Auto.held?({ "tag" => "v9.0.0" })).to be(false)
    end
  end

  describe "central" do
    let(:payload) do
      { "schema" => 1, "version" => { "tag" => "v0.9.3", "channel" => "stable" },
        "server" => { "temp" => 61, "cpu" => 12, "memory" => 40, "disk" => { "used" => 30, "free" => 70 }, "online" => true, "last_outage" => nil, "queue_late" => 0 },
        "backup" => { "offsite_at" => 1.hour.ago.iso8601, "restore_ok" => true }, "health" => { "server" => { "status" => "ok", "problems" => 0 } },
        "house" => { "devices" => 12, "points_unavailable" => 0 } }
    end

    def report(token, body = payload) = post("/api/v1/integrador/resumo", params: body, as: :json, headers: { "Authorization" => "Bearer #{token}" })

    it "só existe com INTEGRATOR_HUB=1; token errado = 404; o resumo grava, responde o freio e vira amostra" do
      inst, token = within(tenant) { Installation.create_with_token!(name: "Casa do João") }
      report(token)
      expect(response).to have_http_status(:not_found)

      ENV["INTEGRATOR_HUB"] = "1"
      report("errado")
      expect(response).to have_http_status(:not_found)
      within(tenant) { inst.update!(max_version: "v0.9.3") }
      report(token)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("max_version" => "v0.9.3", "status" => "ok")
      expect(inst.reload).to have_attributes(version_tag: "v0.9.3", status: "ok")
      expect(inst.samples.pluck(:temp)).to eq([ 61 ])
    end

    it "avisa o problema uma vez e o 'voltou'; sem sinal só pelo relógio; queda contada avisa uma vez" do
      ENV["INTEGRATOR_HUB"] = "1"
      inst, token = within(tenant) { Installation.create_with_token!(name: "Casa do João") }
      report(token, payload.deep_merge("server" => { "temp" => 93 }))
      report(token, payload.deep_merge("server" => { "temp" => 94 }))
      expect(titles).to eq([ "Casa do João: servidor a 93 °C" ])
      expect(inst.reload.status).to eq("error")
      report(token)
      expect(titles.last).to eq("Casa do João: voltou ao normal (Servidor quente)")

      outage = { "kind" => "network", "from" => 2.hours.ago.iso8601, "to" => 1.hour.ago.iso8601, "seconds" => 3600 }
      report(token, payload.deep_merge("server" => { "last_outage" => outage }))
      report(token, payload.deep_merge("server" => { "last_outage" => outage }))
      expect(titles.last).to eq("Casa do João: o servidor ficou sem internet por 1 h")
      expect(titles.count { |t| t.include?("sem internet por") }).to eq(1)

      travel(20.minutes) { Integrator::Watch.tick }
      expect(titles.last).to start_with("Casa do João: sem sinal desde")
      expect(inst.reload.status).to eq("offline")
    end

    it "a primeira queda que a instalação conta não vira aviso (é história de antes de ligar a central)" do
      ENV["INTEGRATOR_HUB"] = "1"
      _inst, token = within(tenant) { Installation.create_with_token!(name: "Loja") }
      report(token, payload.deep_merge("server" => { "last_outage" => { "kind" => "off", "from" => 3.days.ago.iso8601, "to" => 3.days.ago.iso8601, "seconds" => 600 } }))
      expect(titles).to be_empty
    end

    it "a tela: só o dono e só na central; cria com o token uma vez, mostra o resumo e salva o freio" do
      sign_in
      get "/integrador"
      expect(response).to have_http_status(:not_found)
      ENV["INTEGRATOR_HUB"] = "1"
      get "/integrador"
      expect(response.body).to include("Nenhuma instalação ainda")
      post "/integrador", params: { installation: { name: "Casa do João" } }
      expect(response.body).to include("INTEGRATOR_TOKEN=ma_inst_", "Instalação Casa do João criada")
      inst = within(tenant) { Installation.last }
      get "/integrador/#{inst.id}"
      expect(response.body).to include("Casa do João", "Ainda não chegou nenhum resumo")
      patch "/integrador/#{inst.id}", params: { installation: { name: "Casa do João", max_version: "v0.9.3" } }
      expect(inst.reload.max_version).to eq("v0.9.3")
      patch "/integrador/#{inst.id}", params: { installation: { name: "Casa do João", max_version: "qualquer" } }
      expect(inst.reload.max_version).to eq("v0.9.3")

      member = create(:user, tenant: tenant, role: "member", email: "membro.integ@ex.com")
      sign_in(member)
      get "/integrador"
      expect(response).to redirect_to("/")
    end
  end
end
