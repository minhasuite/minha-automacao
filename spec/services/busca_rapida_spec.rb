require "rails_helper"

# Busca global de verdade (fontes como plugins, tolerância a acento e erro de
# digitação, nota e recentes) e abertura mais rápida dos painéis (visão sob
# demanda, pré-aquecimento e menos consultas no Resolver). docs/busca.md e docs/desempenho.md.
RSpec.describe "Busca rápida e painel rápido" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:sala) { within(tenant) { create(:area, site: site, name: "Sala de Estar") } }
  let(:cozinha) { within(tenant) { create(:area, site: site, name: "Cozinha") } }
  let(:abajur) { within(tenant) { create(:device, site: site, area: sala, name: "Abajur", driver: "virtual") } }
  let!(:luz) { within(tenant) { create(:point, device: abajur, name: "Luz", capability: "onoff", value: false, writable: true) } }
  let!(:tomada) { within(tenant) { create(:point, device: create(:device, site: site, area: sala, name: "Tomada TV", driver: "virtual"), name: "Tomada", capability: "onoff", value: true, writable: true) } }
  let!(:temp) { within(tenant) { create(:point, device: create(:device, site: site, area: cozinha, name: "Sensor", driver: "virtual"), name: "Temperatura", capability: "measure", unit: "°C", value: 22.5) } }
  let!(:camera) { within(tenant) { create(:point, device: create(:device, site: site, area: sala, name: "DVR", driver: "virtual"), name: "Câmera da Garagem", capability: "stream") } }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  before { allow(Drivers).to receive(:supported?).and_return(true) }

  def kinds(q, who = user) = Search.call(q, who).map(&:type)
  def titles(q, who = user) = Search.call(q, who).map(&:title)

  describe Search::Match do
    it "sem acento, começo de palavra e erro de digitação de uma letra (duas em palavra longa)" do
      expect(described_class.score(%w[sala], "Sala de Estar")).to eq(4.5)
      expect(described_class.score(%w[est], "Sala de Estar")).to eq(3.0)
      expect(described_class.score(%w[cozinah], "Cozinha")).to eq(0.75) # troca
      expect(described_class.score(%w[temperatrua], "Temperatura")).to be_present
      expect(described_class.score(%w[cozin], "Cozinha")).to be_present
      expect(described_class.score(%w[sla], "Sala")).to be_nil # termo curto não tem tolerância
      expect(described_class.score(%w[sala garagem], "Sala")).to be_nil # todos os termos
      expect(described_class.score([], "x")).to eq(0)
      expect(described_class.near?("abc", "abcdef", 1)).to be(false)
    end
  end

  describe "fontes" do
    it "aparelho, ponto, câmera, área, card de painel (painel e visão), configuração e tolerância a erro" do
      definition = { "schema_version" => 1, "views" => [ { "id" => "v-sala", "title" => "Sala", "path" => "sala", "sections" => [ { "id" => "s", "title" => "S", "widgets" => [
        { "id" => "w-luz", "type" => "tile", "bind" => luz.id },
        { "id" => "w-adm", "type" => "tile", "bind" => tomada.id, "label" => "Tomada secreta", "visible_if" => { "role" => [ "technician" ] } } ] } ] } ] }
      dashboard = site.dashboards.create!(name: "Principal", kind: "custom", definition: definition).tap { |d| d.publish!(definition) }

      expect(kinds("abajur")).to include("device", "point")
      expect(kinds("garagem")).to eq([ "camera" ]) # câmera tem fonte própria
      expect(Search.call("garagem", user).first.target).to include(type: "point", id: camera.id)
      expect(kinds("cozinah")).to include("area", "point") # erro de digitação
      expect(Search.call("temperatrua", user).map(&:key)).to include("point:#{temp.id}")

      card = Search.call("luz", user).find { |r| r.type == "widget" }
      expect(card.subtitle).to eq("Principal · Sala")
      expect(card.url).to eq("/paineis/#{dashboard.id}?view=sala#w-luz")
      expect(card.target).to include(type: "dashboard", id: dashboard.id, view: "v-sala", widget_id: "w-luz")

      guest = create(:user, tenant: tenant, role: "member")
      create(:site_membership, site: site, user: guest, role: "guest")
      expect(titles("secreta")).to include("Tomada secreta") # dono vê
      expect(titles("secreta", guest)).not_to include("Tomada secreta") # visible_if.role

      expect(titles("senha")).to include(I18n.t("security.nav")) # configuração pelas palavras
      expect(kinds("integracao", guest)).not_to include("integration")
    end

    it "integração, automação e script só para quem cadastra; script executa com papel x risco" do
      within(tenant) { site.integrations.create!(driver: "calendar", name: "Agenda da família") }
      script = site.scripts.create!(name: "Boa noite", definition: { "actions" => [ { "type" => "command", "point" => luz.id, "command" => "off" } ] }, version: 1)
      site.automations.create!(name: "Boa noite automática")
      guest = create(:user, tenant: tenant, role: "member")
      create(:site_membership, site: site, user: guest, role: "guest")

      expect(kinds("agenda familia")).to eq([ "integration" ])
      expect(kinds("agenda familia", guest)).to eq([])
      expect(kinds("boa noite")).to include("script", "automation")
      expect(kinds("boa noite", guest)).to eq(%w[script point]) # a automação como ponto (liga/desliga), não o editor

      run = Search.call("executar script boa noite", user)
      expect(run.map(&:type)).to eq([ "script" ])
      expect(run.first.action).to include(label: "Executar", url: "/automacoes/#{script.id}/executar")
      expect(run.first.api).to eq(path: "/scripts/#{script.id}/run", body: {})

      script.update!(fields: [ { "name" => "quarto", "label" => "Quarto", "type" => "text", "required" => true } ])
      expect(Search.call("executar boa noite", user)).to eq([]) # com campo obrigatório: abre o formulário, não executa
      expect(Search.call("boa noite", guest).first.url).to eq("/automacoes/#{script.id}/executar")
    end

    it "'ligar luz da sala': prefere as luzes, traz a ação e a API com client_uuid" do
      results = Search.call("ligar luz da sala", user)
      expect(results.map(&:title)).to eq([ "Luz" ]) # a tomada também liga, mas não é luz
      expect(results.first.api[:path]).to eq("/points/#{luz.id}/commands")
      expect(results.first.api[:body]).to include(command: "on", client_uuid: be_present)
    end

    it "ordem: nome inteiro, recentes e favoritos sobem; grupos pela melhor nota" do
      expect(Search.call("cozinha", user).first.type).to eq("area")
      first = Search.call("sala", user).first
      Search::Recent.add!(user, Search.lookup("point:#{tomada.id}", Search::Context.for(user)))
      boosted = Search.call("sala", user)
      expect(boosted.first.key).to eq("point:#{tomada.id}")
      expect(boosted.first.recent).to be(true)
      expect(first.key).not_to eq("point:#{tomada.id}")

      Dashboards::Personal.toggle!(user.reload, temp, true)
      expect(Search.call("sensor", user).find { |r| r.key == "point:#{temp.id}" }.favorite).to be(true)
    end

    it "recentes: guarda o retrato, relê pela chave e some o que não existe mais" do
      ctx = Search::Context.for(user)
      %W[point:#{luz.id} area:#{sala.id} device:#{abajur.id} camera:#{camera.id} page:root_path setting:security].each do |k|
        r = Search.lookup(k, ctx)
        expect(r&.key).to eq(k)
        Search::Recent.add!(user, r)
      end
      expect(Search::Recent.entries(user.reload).first).to include("k" => "setting:security", "u" => "/configuracoes/seguranca")
      expect(Search.recent(user).size).to eq(6)
      expect(Search.lookup("point:nao-existe", ctx)).to be_nil
      expect(Search.lookup("nada", ctx)).to be_nil
      expect(Search.lookup("xyz:1", ctx)).to be_nil
      Search::Recent.add!(user, nil)
      expect(Search::Recent.keys(user.reload).size).to eq(6)
    end
  end

  describe "painel: só a visão aberta, pré-aquecimento e menos consultas" do
    let(:definition) do
      { "schema_version" => 1, "start_view" => "v2", "views" => [
        { "id" => "v1", "title" => "Um", "sections" => [ { "id" => "s1", "title" => "S", "widgets" => [ { "id" => "w1", "type" => "tile", "bind" => luz.id } ] } ] },
        { "id" => "v2", "title" => "Dois", "path" => "dois", "sections" => [ { "id" => "s2", "title" => "S", "widgets" => [
          { "id" => "w2", "type" => "area_card", "area" => sala.id }, { "id" => "w3", "type" => "tile", "bind" => temp.id } ] } ] } ] }
    end
    let(:dashboard) { site.dashboards.create!(name: "Casa", kind: "custom", definition: definition).tap { |d| d.publish!(definition) } }

    after do
      Dashboards::Cache.enabled = nil
      Dashboards::Cache.clear!
    end

    it "resolve só a visão que abre (start_view) ou a pedida; as outras vêm `lazy` e sem widgets" do
      out = Dashboards::Resolver.new(dashboard, role: "owner", only_view: :open).call
      v1, v2 = out["views"]
      expect(v1).to include("lazy" => true, "sections" => [], "badges" => [], "title" => "Um")
      expect(v2["lazy"]).to be_nil
      expect(v2["sections"].first["widgets"].map { _1["id"] }).to eq(%w[w2 w3])
      expect(out["points"].keys).not_to include(luz.id)

      other = Dashboards::Resolver.new(dashboard, role: "owner", only_view: "v1").call
      expect(other["views"].first["sections"].first["widgets"].map { _1["id"] }).to eq(%w[w1])
      expect(Dashboards::Resolver.new(dashboard, role: "owner", only_view: "dois").call["views"].last["lazy"]).to be_nil
      expect(Dashboards::Resolver.new(dashboard, role: "owner").call["views"].none? { _1["lazy"] }).to be(true)
    end

    it "cache em dois níveis: o pré-aquecido (cache comum) serve outro processo" do
      Dashboards::Cache.enabled = true
      shared = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(shared)
      dashboard.update!(site_default: true)
      expect(Dashboards::Prewarm.targets(site).map { |d, role| [ d.id, role ] }).to include([ dashboard.id, "owner" ])
      expect(Dashboards::Prewarm.run(site)).to be >= 1

      Dashboards::Cache::STORE.clear # "outro processo": só o cache comum
      expect(Dashboards::Resolver).not_to receive(:new)
      payload = Dashboards::Cache.resolved(dashboard, role: "owner", lazy: true)
      expect(payload["views"].first["lazy"]).to be(true)
    end

    it "touch com debounce enfileira um job por local; o job resolve; desligado nos testes" do
      expect { Dashboards::Prewarm.touch(site.id) }.not_to have_enqueued_job(DashboardPrewarmJob)
      Dashboards::Cache.enabled = true
      Dashboards::Prewarm.instance_variable_get(:@due).clear
      expect { Dashboards::Prewarm.touch(site.id) }.to have_enqueued_job(DashboardPrewarmJob).with(site.id)
      expect { Dashboards::Prewarm.touch(site.id) }.not_to have_enqueued_job(DashboardPrewarmJob)
      expect(Dashboards::Prewarm).to receive(:run).with(site)
      DashboardPrewarmJob.perform_now(site.id)
      DashboardPrewarmJob.perform_now("nao-existe")
      allow(DashboardPrewarmJob).to receive(:set).and_raise("fila fora")
      Dashboards::Prewarm.instance_variable_get(:@due).clear
      expect { Dashboards::Prewarm.touch(site.id) }.not_to raise_error
    end

    it "consulta por área começa pelos pontos da área (id ou nome), com o mesmo resultado" do
      q = Points::Query.new(site)
      expect(q.call({ "area" => sala.id }).map(&:name)).to contain_exactly("Luz", "Tomada", "Câmera da Garagem")
      expect(q.call({ "area" => "sala de estar" }).map(&:name)).to contain_exactly("Luz", "Tomada", "Câmera da Garagem")
      expect(q.call({ "area" => "#{sala.id},#{cozinha.id}" }).size).to eq(4)
      expect(q.call({ "area" => "Nenhuma" })).to eq([])
    end

    it "sem N+1: automações, cenas e modelos de card numa consulta só" do
      5.times { |i| site.automations.create!(name: "A#{i}") }
      3.times { |i| site.scenes.create!(name: "C#{i}", items: [ { "point_id" => luz.id, "command" => "on" } ]) }
      auto_points = Point.where(site_id: site.id).select { AutomationPoints.automation?(_1) }
      defn = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "title" => "S", "widgets" => [
        *auto_points.map { |p| { "id" => "a#{p.id}", "type" => "tile", "bind" => p.id } }, { "id" => "sb", "type" => "scene_bar" },
        { "id" => "t1", "type" => "template", "template" => "area", "vars" => { "area" => sala.id } },
        { "id" => "t2", "type" => "template", "template" => "area", "vars" => { "area" => cozinha.id } } ] } ] } ] }
      d = site.dashboards.create!(name: "N", kind: "custom", definition: defn).tap { |x| x.publish!(defn) }
      sql = []
      cb = ->(*, payload) { sql << payload[:sql] }
      ActiveSupport::Notifications.subscribed(cb, "sql.active_record") { Dashboards::Resolver.new(d, role: "owner").call }
      expect(sql.grep(/FROM "automations"/).size).to eq(1)
      expect(sql.grep(/FROM "card_templates"/).size).to eq(1)
      expect(sql.grep(/FROM "points" WHERE .*"points"."id" =/).size).to eq(0) # risco da cena pelos pontos já lidos
      expect(Dashboards::Resolver.point_json(auto_points.first, "owner")).to have_key("can_command") # fora do Resolver continua lendo
      expect(site.scenes.first.risk).to eq("normal")
    end
  end
end
