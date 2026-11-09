require "rails_helper"

# Web no celular: retorno imediato do comando, lista de dispositivos de toque,
# filtros da gem, tempo curto nos avisos e a barra do sistema no tema.
RSpec.describe "Web no celular" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:area) { within(tenant) { create(:area, site: site, name: "Sala") } }
  let!(:device) { within(tenant) { create(:device, site: site, area: area, name: "Interruptor") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Luz da sala", value: false, writable: true, changed_at: 1.minute.ago) } }

  before { post "/entrar", params: { email: user.email, password: "12345678" } }

  def sent!(point, cmd = "on", status: "sent")
    within(tenant) { Command.create!(site: site, point: point, command: cmd, source: "web", status: status, user: user) }
  end

  it "comando a caminho: o tile do Início e o da página do ponto já mostram ligado, enviando" do
    sent!(lamp)
    get "/"
    tile = Nokogiri::HTML(response.body).css(".ss-device").find { |d| d.text.include?("Luz da sala") }
    expect(tile["data-status"]).to eq("pending")
    expect(tile["class"]).to include("is-on")
    expect(tile.text).to include("Ligado")

    get "/pontos/#{lamp.id}"
    tile = Nokogiri::HTML(response.body).at_css(".ss-device")
    expect(tile["data-status"]).to eq("pending")
    expect(tile.at_css(".ss-device-more")["href"]).to eq("/pontos/#{lamp.id}/editar")
  end

  it "comando que falhou deixa o tile em erro, no estado de verdade" do
    sent!(lamp, status: "failed")
    get "/pontos/#{lamp.id}"
    tile = Nokogiri::HTML(response.body).at_css(".ss-device")
    expect(tile["data-status"]).to eq("error")
    expect(tile["class"]).not_to include("is-on")
  end

  it "ao confirmar ou falhar, o comando avisa as telas abertas" do
    command = sent!(lamp, status: "pending")
    allow(Drivers).to receive(:for).and_raise(StandardError, "sem resposta") # o aparelho não diz nada: só o aviso do comando
    expect { ExecuteCommandJob.perform_now(command.id) }.to have_broadcasted_to("#{site.to_gid_param}:points")
    expect(command.reload.status).to eq("failed")
  end

  it "lista de dispositivos de toque no celular e filtros da gem; a página do ponto junta o que está vazio" do
    get "/locais/#{site.id}/dispositivos"
    doc = Nokogiri::HTML(response.body)
    row = doc.at_css("ul.ss-rows li")
    expect(row.text).to include("Interruptor", "Sala", "1 ponto")
    expect(row.at_css("a")["href"]).to eq("/dispositivos/#{device.id}")
    expect(doc.css(".ss-filterbar, [class*='ss-filter']")).not_to be_empty

    get "/locais/#{site.id}/automacoes"
    expect(response).to have_http_status(:ok)

    get "/pontos/#{lamp.id}"
    doc = Nokogiri::HTML(response.body)
    spare = doc.at_css("section[aria-label='#{I18n.t('automations.lists.not_set')}']")
    expect(spare.css("li").size).to eq(4)
  end

  it "alertas e notificações com o tempo curto; barra do sistema no tema" do
    within(tenant) do
      rule = create_rule
      Alert.create!(site: site, alert_rule: rule, point: lamp, opened_at: 40.minutes.ago)
      Notification.create!(user: user, kind: "sistema", title: "Backup concluído")
    end
    get "/alertas"
    expect(response.body).to include("há 40 min")
    get "/notificacoes"
    expect(response.body).to match(%r{<time datetime="[^"]+" title="[^"]+">há 1 min</time>})
    expect(response.body).to include('name="theme-color" content="#f6f5fb" media="(prefers-color-scheme: light)"',
                                      'name="apple-mobile-web-app-status-bar-style" content="default"')
  end

  def create_rule = AlertRule.create!(site: site, point: lamp, name: "Luz acesa", operator: "eq", value: true, severity: "warning")
end
