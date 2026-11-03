require "rails_helper"

# appweb: telas da web pelo app (AppScreen). A página que o navegador recebe
# vira blocos; o envio do formulário passa pelo mesmo controlador da web. O
# formulário de plugin (aqui um plugin de integração falso, com a partial
# dele) chega ao app sem tela fixa por tipo.
RSpec.describe "Telas do servidor no app (appweb)" do
  let(:user) { create(:user, name: "Teste Dono") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Teste Casa") } }

  def screen(path) = get("/api/v1/screen", params: { path: path }, headers: auth_headers(user))
  def submit(path, fields, method: "post") = post("/api/v1/screen", params: { path: path, method: method, fields: fields }, headers: auth_headers(user), as: :json)
  def page = response.parsed_body.dig("data", "page")
  def walk(blocks, &) = blocks.each { |b| yield b; walk(Array(b["c"]), &); Array(b["rows"]).flatten.each { |c| walk(Array(c), &) } if b["rows"] }
  def all_blocks = [].tap { |out| walk(page["blocks"] + page["actions"].to_a) { |b| out << b } }

  it "exige o token do app" do
    get "/api/v1/screen", params: { path: "/configuracoes" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "não abre rota fora da web nem as de sessão" do
    [ "/api/v1/me", "/entrar", "//exemplo.com", "/nao-existe", "https://exemplo.com/" ].each do |p|
      screen(p)
      expect(response).to have_http_status(:not_found), p
    end
  end

  it "transcodifica a tela: título, voltar, submenu, selos e o menu lateral" do
    screen("/configuracoes/saude")
    expect(response).to have_http_status(:ok)
    expect(page["title"]).to be_present
    expect(page["menu"].map { |m| m["href"] }).to include("/configuracoes")
    sub = all_blocks.find { |b| b["t"] == "subnav" }
    expect(sub["items"]).to include(a_hash_including("href" => "/configuracoes/saude", "current" => true))
    expect(all_blocks.map { |b| b["t"] }).to include("card", "badge", "heading")
    expect(all_blocks.select { |b| b["t"] == "heading" }.map { |b| b["icon"] }).to include("shield-check")
  end

  describe "formulário de plugin de integração (plugin falso por stub_const)" do
    let(:fake) do
      Class.new(Integrations::Plugin) do
        describe key: "teste_app", title: "Teste App", icon: "cube", description: "Plugin falso", driver: "virtual"
        def self.setup(site, form)
          return outcome(:form, alert: "Informe o endereço.") if form[:host].blank?

          integ = new_integration(site, name: form[:name].presence || title, settings: { "host" => form[:host], "modo" => form[:modo] })
          integ.save!
          outcome(:list, integration: integ, notice: "Teste App conectado.")
        end
      end
    end
    let(:views) { Dir.mktmpdir }

    before do
      stub_const("Integrations::TesteAppPlugin", fake)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[TesteAppPlugin])
      FileUtils.mkdir_p("#{views}/web/integrations/forms")
      File.write("#{views}/web/integrations/forms/_teste_app.html.erb", <<~ERB)
        <div><%= f.label :host, "Endereço", class: "ss-label" %><%= f.text_field :host, class: "ss-input", placeholder: "192.168.0.9", required: true %></div>
        <div><%= f.label :modo, "Modo", class: "ss-label" %><%= f.select :modo, [["Rápido", "r"], ["Lento", "l"]], {}, class: "ss-input" %></div>
        <label><%= f.check_box :local %> Só na rede local</label>
      ERB
      Web::IntegrationsController.prepend_view_path(views)
    end

    after { FileUtils.rm_rf(views) }

    it "chega como campos e o envio cria pela mesma regra da web, com o aviso" do
      screen("/locais/#{site.id}/integracoes/nova?tipo=teste_app")
      expect(response).to have_http_status(:ok)
      form = all_blocks.find { |b| b["t"] == "form" }
      expect(form).to include("method" => "post")
      fields = all_blocks.select { |b| b["t"] == "field" }.index_by { |f| f["name"] }
      expect(fields["integration[host]"]).to include("kind" => "text", "label" => "Endereço", "placeholder" => "192.168.0.9", "required" => true)
      expect(fields["integration[modo]"]["options"].map { |o| o["value"] }).to eq(%w[r l])
      expect(fields["integration[local]"]).to include("kind" => "checkbox", "label" => "Só na rede local", "checked" => false)
      expect(all_blocks).to include(a_hash_including("t" => "submit"))

      submit(form["action"], form["hidden"] + [ [ "integration[host]", "" ] ])
      expect(response.parsed_body.dig("meta", "status")).to eq(422)
      expect(page["flash"]).to include(a_hash_including("tone" => "danger", "text" => "Informe o endereço."))

      submit(form["action"], form["hidden"] + [ [ "integration[host]", "10.0.0.9" ], [ "integration[modo]", "l" ] ])
      expect(response.parsed_body.dig("meta", "status")).to eq(200)
      expect(page["path"]).to eq("/locais/#{site.id}/integracoes")
      expect(page["flash"]).to include(a_hash_including("tone" => "success", "text" => "Teste App conectado."))
      expect(within(tenant) { site.integrations.find_by(driver: "virtual").settings }).to include("host" => "10.0.0.9", "modo" => "l")
    end
  end

  it "respeita o papel: leitor não abre a tela de técnico" do
    reader = create(:user, tenant: tenant, name: "Teste Leitor", role: "member")
    get "/api/v1/screen", params: { path: "/locais/#{site.id}/integracoes/nova?tipo=shelly" }, headers: auth_headers(reader)
    expect(response.parsed_body.dig("data", "page", "blocks").to_s).not_to include("integration[host]")
  end

  it "link de uso único abre a web já logado, uma vez só" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    post "/api/v1/screen/bridge", params: { to: "/configuracoes/seguranca" }, headers: auth_headers(user)
    url = response.parsed_body.dig("data", "url")
    expect(url).to include("/entrar/ponte?t=")
    get URI.parse(url).request_uri
    expect(response).to redirect_to("/configuracoes/seguranca")
    get "/configuracoes/seguranca"
    expect(response).to have_http_status(:ok)
    reset!
    get URI.parse(url).request_uri
    expect(response).to redirect_to(login_path)
  end

  # Toda tela de configuração da web abre pelo app (sem erro e com título).
  # APPWEB_DUMP=dir grava as páginas (fixtures das capturas do app).
  it "abre as telas de configuração da web" do
    sala = within(tenant) { create(:area, site: site, name: "Sala") }
    dev = within(tenant) { create(:device, site: site, area: sala, name: "Teste Luminária", driver: "virtual") }
    pt = within(tenant) { create(:point, device: dev, site: site, name: "Luz", capability: "onoff") }
    auto = within(tenant) { site.automations.create!(name: "Teste Luz ao anoitecer") }
    paths = {
      "configuracoes" => "/configuracoes", "sistema" => "/configuracoes/sistema", "saude" => "/configuracoes/saude",
      "seguranca" => "/configuracoes/seguranca", "pessoas" => "/configuracoes/pessoas", "backups" => "/configuracoes/backups",
      "aparencia" => "/configuracoes/aparencia", "rotulos" => "/configuracoes/rotulos", "plano" => "/configuracoes/plano",
      "acesso_remoto" => "/configuracoes/acesso-remoto", "ia" => "/configuracoes/ia", "logs" => "/configuracoes/logs",
      "conta" => "/configuracoes/conta", "paineis" => "/configuracoes/paineis", "aplicativos" => "/configuracoes/aplicativos",
      "local" => "/locais/#{site.id}", "integracoes" => "/locais/#{site.id}/integracoes",
      "integracao_nova" => "/locais/#{site.id}/integracoes/nova?tipo=shelly", "dispositivos" => "/locais/#{site.id}/dispositivos",
      "dispositivo" => "/dispositivos/#{dev.id}", "ponto" => "/pontos/#{pt.id}/editar", "area" => "/areas/#{sala.id}/editar",
      "regras" => "/locais/#{site.id}/regras", "automacao" => "/automacoes/#{auto.id}/editar", "automacao_json" => "/automacoes/#{auto.id}/json",
      "scripts" => "/locais/#{site.id}/scripts", "cenas" => "/locais/#{site.id}/cenas", "blueprints" => "/locais/#{site.id}/blueprints",
      "helpers" => "/locais/#{site.id}/helpers", "helper_novo" => "/locais/#{site.id}/helpers/novo?tipo=timer",
      "assistente" => "/locais/#{site.id}/assistente", "expor" => "/locais/#{site.id}/expor", "listas" => "/locais/#{site.id}/listas",
      "agenda" => "/locais/#{site.id}/agenda", "pacotes" => "/locais/#{site.id}/pacotes", "ferramentas" => "/locais/#{site.id}/ferramentas",
      "prontos" => "/locais/#{site.id}/paineis/prontos", "busca" => "/busca?q=luz", "perguntar" => "/perguntar"
    }
    dir = ENV["APPWEB_DUMP"].presence
    FileUtils.mkdir_p(dir) if dir
    paths.each do |name, path|
      screen(path)
      expect(response).to have_http_status(:ok), path
      expect(response.parsed_body.dig("meta", "status")).to eq(200), "#{path}: #{response.parsed_body.dig('meta', 'status')}"
      expect(page["title"]).to be_present, path
      File.write("#{dir}/#{name}.json", JSON.pretty_generate(response.parsed_body)) if dir
    end
  end
end
