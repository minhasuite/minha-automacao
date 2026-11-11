require "rails_helper"

# Performance (proposta de personalização, itens 1–10): cache do painel,
# avisos agrupados, banda morta padrão, quadro de câmera sem bloquear,
# medição por tela/widget na Saúde e fila das tarefas lentas.
RSpec.describe "Performance" do
  let(:tenant) { create(:tenant) }
  let(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:area) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let(:device) { within(tenant) { create(:device, site: site, area: area, name: "Tomada", driver: "virtual") } }
  let!(:luz) { within(tenant) { create(:point, device: device, name: "Luz", capability: "onoff", value: false) } }
  let!(:potencia) { within(tenant) { create(:point, device: device, name: "Potência", capability: "measure", unit: "W", device_class: "power", value: 100.0) } }
  let(:definition) do
    { "schema_version" => 1, "views" => [ { "id" => "home", "title" => "Início", "sections" => [
      { "id" => "s1", "title" => "Sala", "widgets" => [ { "id" => "w-area", "type" => "area_card", "area" => area.id },
                                                         { "id" => "w-luz", "type" => "tile", "bind" => luz.id } ] } ] } ] }
  end
  let(:dashboard) { within(tenant) { site.dashboards.create!(name: "Casa", kind: "home", definition: definition).tap { |d| d.publish!(definition) } } }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  describe Dashboards::Cache do
    after do
      described_class.enabled = nil
      described_class.clear!
    end

    it "lista de pontos guardada pelo carimbo: igual sem mudança, nova com qualquer gravação (até update_column)" do
      first = described_class.points(site)
      expect(first.map(&:name)).to eq(%w[Luz Potência])
      expect(first.first.device.name).to eq("Tomada")
      expect(first.first).not_to equal(described_class.points(site).first) # cada pedido monta os próprios objetos
      expect(described_class).not_to receive(:load_rows)
      described_class.points(site)
    end

    it "valor novo (inclusive por update_column) entra na próxima leitura" do
      described_class.points(site)
      luz.update_column(:value, true) # rubocop:disable Rails/SkipsModelValidations
      expect(described_class.points(site).find { |p| p.id == luz.id }.value).to be(true)
      potencia.report!(250.0)
      expect(described_class.points(site).find { |p| p.id == potencia.id }.value).to eq(250.0)
    end

    it "painel resolvido guardado por papel e invalidado pelo ponto" do
      described_class.enabled = true
      expect(Dashboards::Resolver).to receive(:new).twice.and_call_original
      a = Dashboards::Resolver.cached(dashboard, role: "owner")
      b = Dashboards::Resolver.cached(dashboard, role: "owner")
      expect(b).to eq(a)
      luz.report!(true)
      c = Dashboards::Resolver.cached(dashboard, role: "owner")
      expect(c.dig("points", luz.id, "value")).to be(true)
    end

    it "papel diferente não reaproveita; desligado (testes) sempre resolve" do
      described_class.enabled = true
      Dashboards::Resolver.cached(dashboard, role: "owner")
      expect(Dashboards::Resolver).to receive(:new).and_call_original
      Dashboards::Resolver.cached(dashboard, role: "guest")
      described_class.enabled = false
      expect(Dashboards::Resolver).to receive(:new).and_call_original
      Dashboards::Resolver.cached(dashboard, role: "owner")
    end

    it "o que não se copia só não fica guardado" do
      described_class.enabled = true
      allow(described_class::STORE).to receive(:write).and_raise(TypeError, "no _dump_data")
      expect(Dashboards::Resolver.cached(dashboard, role: "owner")["views"]).to be_present
    end

    it "recarga de um widget resolve só ele com a lista do cache" do
      r = Dashboards::Resolver.new(dashboard, role: "owner")
      w = r.widget("w-area")
      expect(w["data"]).to include("total" => 2)
      expect(r.points_payload.keys).to be_empty # o cartão da área não põe pontos no payload
      expect(Dashboards::Resolver.new(dashboard, role: "owner").widget("w-luz")["deps"]).to eq([ luz.id ])
    end
  end

  describe Points::Broadcast do
    before do
      described_class.enabled = true
      described_class.reset!
    end

    after { described_class.enabled = nil }

    it "medição: a primeira mudança sai na hora; as da janela viram um aviso no fim" do
      tasks = []
      allow(Concurrent::ScheduledTask).to receive(:execute) { |delay, &blk| tasks << [ delay, blk ] }
      allow(described_class).to receive(:send!)
      potencia.report!(200.0)
      potencia.report!(201.0)
      potencia.report!(202.0)
      expect(described_class).to have_received(:send!).once
      expect(tasks.size).to eq(1)
      expect(tasks.first[0]).to be_between(0, described_class::WINDOW)
      tasks.first[1].call
      expect(described_class).to have_received(:send!).twice
      potencia.report!(203.0) # janela nova depois do aviso guardado: agrupa de novo
      expect(tasks.size).to eq(2)
    end

    it "liga/desliga e mudança de qualidade avisam sempre na hora; notify_s 0 tira o agrupamento" do
      allow(described_class).to receive(:send!)
      luz.report!(true)
      luz.report!(false)
      potencia.report!(300.0)
      potencia.report!(300.0, quality: "unavailable")
      expect(described_class).to have_received(:send!).exactly(4).times
      potencia.update!(address: { "notify_s" => 0 })
      potencia.report!(301.0)
      potencia.report!(302.0)
      expect(described_class).to have_received(:send!).exactly(6).times
    end

    it "manda o refresh do ponto e o point_changed do local" do
      expect { described_class.changed(luz) }.to have_broadcasted_to("#{site.to_gid_param}:points")
      expect { described_class.trailing(luz.to_gid_param, site.to_gid_param, luz.id) }.to have_broadcasted_to(luz.to_gid_param)
      allow(described_class).to receive(:send!).and_raise("cable")
      allow(Rails.error).to receive(:report)
      described_class.trailing(luz.to_gid_param, site.to_gid_param, luz.id)
      expect(Rails.error).to have_received(:report).at_least(:once)
    end

    it "nos testes não agrupa" do
      described_class.enabled = nil
      expect(described_class.window(potencia)).to eq(0.0)
    end
  end

  describe Points::Deadband do
    it "padrão por unidade e classe; a do ponto (até 0) manda; acumulador e não medição sem banda" do
      expect(described_class.for(potencia)).to eq(1)
      tensao = create(:point, device: device, name: "Tensão", capability: "measure", unit: "V")
      expect(described_class.for(tensao)).to eq(0.5)
      fp = create(:point, device: device, name: "FP", capability: "measure", unit: "", device_class: "power_factor")
      expect(described_class.for(fp)).to eq(0.01)
      potencia.update!(deadband: 0)
      expect(described_class.for(potencia)).to eq(0)
      energia = create(:point, device: device, name: "Energia", capability: "measure", unit: "W", state_class: "total_increasing")
      expect(described_class.for(energia)).to be_nil
      expect(described_class.for(luz)).to be_nil
    end

    it "histórico grava menos com a banda padrão e tudo com a banda 0 do ponto" do
      [ 100.4, 100.8, 102.0, 102.5 ].each_with_index { |v, i| potencia.report!(v, at: Time.current + i) }
      expect(Reading.where(point_id: potencia.id).order(:at).pluck(:value).map(&:to_f)).to eq([ 100.4, 102.0 ])
      potencia.update!(deadband: 0)
      [ 102.6, 102.7 ].each_with_index { |v, i| potencia.report!(v, at: Time.current + 10 + i) }
      expect(Reading.where(point_id: potencia.id).count).to eq(4)
    end
  end

  describe Drivers::Go2rtc do
    let(:base) { "http://go2rtc:1984" }
    let(:cam_device) { create(:device, site: site, driver: "go2rtc", name: "Câmera", address: { "host" => "192.168.0.12" }) }
    let(:cam) { create(:point, device: cam_device, name: "Quintal", capability: "stream", address: { "path" => "/live" }) }
    let(:nuvem) { create(:point, device: device, name: "Nuvem", capability: "stream", address: { "on_demand" => true }) }
    let(:jpeg) { Vips::Image.black(800, 600).jpegsave_buffer }

    around do |ex|
      old = ENV.fetch("GO2RTC_URL", nil)
      ENV["GO2RTC_URL"] = base
      ex.run
    ensure
      ENV["GO2RTC_URL"] = old
      FileUtils.rm_rf(described_class::SNAPSHOT_DIR)
    end

    before do
      require "vips"
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    end

    it "câmera boa responde na hora com o quadro e a largura pedida (libvips)" do
      stub_request(:get, "#{base}/api/frame.jpeg?src=#{cam.id}").to_return(body: jpeg)
      f = described_class.frame(cam, width: 500)
      expect(f.offline).to be(false)
      expect(Vips::Image.new_from_buffer(f.jpeg, "").width).to eq(640) # cai na menor que cobre
      expect(described_class.frame(cam, width: 500).jpeg).to eq(f.jpeg) # arquivo da largura reaproveitado
      expect(described_class.frame(cam).jpeg).to eq(jpeg)
      expect(described_class.sized(cam, "não é jpeg", 320)).to eq("não é jpeg")
    end

    it "falha: espera dobra a cada falha seguida; depois responde na hora com o último quadro (offline)" do
      stub_request(:get, "#{base}/api/frame.jpeg?src=#{cam.id}").to_return(body: jpeg).then.to_return(status: 500)
      described_class.frame(cam)
      FileUtils.touch(described_class::SNAPSHOT_DIR.join("#{cam.id}.jpg"), mtime: 1.minute.ago.to_time)
      expect { described_class.frame(cam) }.to raise_error(described_class::Error, /500/)
      expect(described_class.failures(cam)).to eq(1)
      expect(described_class.hold_for(1)).to eq(60)
      expect(described_class.hold_for(3)).to eq(240)
      expect(described_class.hold_for(20)).to eq(described_class::MAX_HOLD)
      f = described_class.frame(cam) # segurada: nem vai à rede, devolve o último quadro
      expect(f).to have_attributes(jpeg: jpeg, offline: true)
      expect(WebMock).to have_requested(:get, "#{base}/api/frame.jpeg?src=#{cam.id}").twice
    end

    it "câmera de nuvem sem quadro: busca em segundo plano e responde offline na hora; voltou zera as falhas" do
      allow(described_class).to receive(:on_demand).and_raise(described_class::Error, "Câmera sem conexão (sem vídeo).")
      expect { described_class.frame(nuvem) }.to raise_error(described_class::Error, /sem conexão|sem quadro/i)
      expect(described_class.failures(nuvem)).to eq(1)
      expect { described_class.frame(nuvem) }.to raise_error(described_class::Held)
      Rails.cache.delete("go2rtc:falha:#{nuvem.id}")
      allow(described_class).to receive(:on_demand).and_return("rtsp://nuvem/x")
      stub_request(:put, %r{#{base}/api/streams}).to_return(status: 200)
      stub_request(:get, "#{base}/api/frame.jpeg?src=#{nuvem.id}").to_return(body: jpeg)
      expect(described_class.frame(nuvem).jpeg).to eq(jpeg) # a busca (aqui na hora) já guardou o quadro
      expect(described_class.failures(nuvem)).to eq(0)
    end

    it "quadro velho demais vira offline; busca repetida não sai duas vezes" do
      FileUtils.mkdir_p(described_class::SNAPSHOT_DIR)
      file = described_class::SNAPSHOT_DIR.join("#{nuvem.id}.jpg")
      file.binwrite(jpeg)
      FileUtils.touch(file, mtime: 2.hours.ago.to_time)
      Rails.cache.write("go2rtc:buscando:#{nuvem.id}", true)
      expect { described_class.frame(nuvem) }.to raise_error(described_class::Held, /sem quadro/)
    end
  end

  describe "telas do quadro", type: :request do
    let(:user) { create(:user, tenant: tenant) }
    let(:cam) do
      d = create(:device, site: site, driver: "go2rtc", name: "Câmera", address: { "host" => "192.168.0.12" })
      create(:point, device: d, name: "Quintal", capability: "stream", address: { "path" => "/live" })
    end

    around do |ex|
      old = ENV.fetch("GO2RTC_URL", nil)
      ENV["GO2RTC_URL"] = "http://go2rtc:1984"
      ex.run
    ensure
      ENV["GO2RTC_URL"] = old
      FileUtils.rm_rf(Drivers::Go2rtc::SNAPSHOT_DIR)
    end

    it "web e API mandam a hora do quadro e aceitam ?w=" do
      stub_request(:get, "http://go2rtc:1984/api/frame.jpeg?src=#{cam.id}").to_return(body: "JPEG")
      post "/entrar", params: { email: user.email, password: "12345678" }
      get "/cameras/#{cam.id}/quadro?w=320"
      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Frame-At"]).to be_present
      expect(response.headers["X-Camera-Offline"]).to be_nil
      get "/api/v1/points/#{cam.id}/snapshot?w=320", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Frame-At"]).to be_present
    end
  end

  describe Perf do
    before do
      described_class.reset!
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    end

    it "soma na memória, junta no balde da hora e a Saúde mostra os mais lentos" do
      3.times { described_class.record("screen", "Web::DashboardsController#widget", 100) }
      described_class.record("screen", "Web::DashboardsController#widget", 1900)
      expect(described_class.measure("widget", "area_card") { :ok }).to eq(:ok)
      2.times { described_class.measure("widget", "area_card") { nil } }
      described_class.flush!
      described_class.record("screen", "Web::DashboardsController#widget", 100) # ainda na memória: também conta
      s = described_class.stats.find { |x| x[:key] == "Web::DashboardsController#widget" }
      expect(s).to include(count: 5, max: 1900.0, avg: 460.0)
      items = Health::Checks::Performance.items(tenant)
      expect(items.map(&:title)).to include("Telas: DashboardsController#widget".sub("Controller#", "#"), "Widgets do painel: Área")
      described_class.flush!
      described_class.flush! # nada novo: não grava
    end

    it "média alta vira atenção; sem medição diz que não há" do
      expect(Health::Checks::Performance.items(tenant).map(&:title)).to eq([ "Sem medição ainda" ])
      3.times { described_class.record("widget", "chart", 900) }
      expect(Health::Checks::Performance.items(tenant).first.status).to eq("warn")
    end

    it "mede as telas pelo process_action" do
      ActiveSupport::Notifications.instrument("process_action.action_controller", controller: "Web::PointsController", action: "show") { nil }
      ActiveSupport::Notifications.instrument("process_action.action_controller", controller: "Rails::HealthController", action: "show") { nil }
      keys = described_class.stats.map { |x| x[:key] }
      expect(keys).to include("Web::PointsController#show")
      expect(keys).not_to include("Rails::HealthController#show")
    end

    it "erro ao juntar não derruba o pedido" do
      described_class.record("screen", "X#y", 1)
      allow(Rails.cache).to receive(:read).and_raise("cache fora")
      expect { described_class.flush! }.not_to raise_error
    end
  end

  describe "fila das tarefas lentas" do
    it "varredura, backup e rollup vão para `slow` com o semáforo; comandos na `commands` com prioridade" do
      [ RollupReadingsJob, ReadingsMaintenanceJob, BackupOffsiteJob, SyncIntegrationJob, HaMigrationJob ].each do |job|
        expect(job.new.queue_name).to eq("slow")
        expect(job.new.priority).to eq(10)
        expect(job.concurrency_limit).to eq(SlowJob::LIMIT) if job.respond_to?(:concurrency_limit)
      end
      expect(ExecuteCommandJob.new.queue_name).to eq("commands")
      expect(ExecuteCommandJob.new.priority).to eq(-10)
      expect(YAML.load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true).dig("production", "workers").size).to eq(1)
    end
  end
end
