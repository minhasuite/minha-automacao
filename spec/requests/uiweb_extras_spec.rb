require "rails_helper"

# uiweb: quiosque (tablet de parede), busca global Ctrl+K (fontes por
# registro) e galeria de temas (temas por registro), com plugins falsos.
RSpec::Matchers.define_negated_matcher :not_include, :include

RSpec.describe "Quiosque, busca global e temas" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:area) { within(tenant) { create(:area, site: site, name: "Teste Sala") } }
  let!(:device) { within(tenant) { create(:device, site: site, area: area, name: "Teste Abajur") } }
  let!(:lamp) { within(tenant) { create(:point, device: device, name: "Luz", key: "teste.luz", capability: "onoff", value: true, writable: true) } }
  let!(:gate) { within(tenant) { create(:point, device: device, name: "Teste Portão", capability: "onoff", value: false, writable: true, risk: "critical", confirm: "Abrir mesmo?") } }
  let!(:scene) { within(tenant) { site.scenes.create!(name: "Teste Cinema", items: [ { "point_id" => lamp.id, "command" => "off" } ]) } }
  let(:dashboard) { within(tenant) { Dashboard.ensure_for(site).first } }

  before do
    allow(Drivers).to receive(:supported?).and_return(true)
    post("/entrar", params: { email: user.email, password: "12345678" })
  end

  describe "quiosque" do
    it "?quiosque=1 liga neste aparelho (cookie), sem menu; ajustes e ?quiosque=0 desligam" do
      get "/", params: { quiosque: 1 }
      expect(response.body).to include("ss-kiosk", 'data-controller="kiosk"', "Protetor de tela").and not_include('id="side"')
      get "/"
      expect(response.body).to include('data-controller="kiosk"') # o aparelho lembra

      patch "/quiosque", params: { saver: "cameras", idle: "99", motion: lamp.id, dim: "0" }
      get "/"
      expect(response.body).to include('data-kiosk-saver-value="cameras"', 'data-kiosk-idle-value="60"', %(data-kiosk-motion-value="#{lamp.id}"), 'data-kiosk-dim-value="false"')

      patch "/quiosque", params: { saver: "<script>", idle: "0" }
      get "/"
      expect(response.body).to include('data-kiosk-saver-value="clock"', 'data-kiosk-idle-value="2"')

      get "/", params: { quiosque: 0 }
      expect(response.body).not_to include('data-controller="kiosk"')
      expect(response.body).to include('id="side"')
    end
  end

  describe "busca global" do
    it "acha ponto, área, cena e página; verbo vira ação com confirmação de risco" do
      get "/busca", params: { q: "abajur" }, headers: { "Turbo-Frame" => "palette-results" }
      expect(response.body).to include("palette-results", "Teste Abajur", "Ponto")

      get "/busca", params: { q: "apagar teste abajur" }, headers: { "Turbo-Frame" => "palette-results" }
      expect(response.body).to include("Desligar", %(action="/pontos/#{lamp.id}/comando"))
      expect(within(tenant) { Search.call("desligar teste portao", user) }.first.action).to include(confirm: "Abrir mesmo?", confirm_title: "Crítico")

      results = within(tenant) { Search.call("ativar cena teste cinema", user) }
      expect(results.map(&:kind)).to eq([ "Cena" ])
      expect(results.first.action[:label]).to eq("Ativar")
      expect(within(tenant) { Search.call("configura", user) }.map(&:title)).to include("Configurações")
      expect(within(tenant) { Search.call("teste sala", user) }.map(&:kind)).to include("Área")
      expect(within(tenant) { Search.call("", user) }).to eq([])
    end

    it "quem não comanda não ganha a ação" do
      viewer = create(:user, tenant: tenant, role: "member")
      within(tenant) { create(:site_membership, site: site, user: viewer, role: "guest") }
      expect(within(tenant) { Search.call("desligar teste portao", viewer) }.map(&:action)).to eq([ nil ]) # crítico: visitante não comanda
      expect(within(tenant) { Search.call("apagar teste abajur luz", viewer) }.first.action).to be_present # normal: visitante comanda (papel × risco)
    end

    it "fonte nova por stub_const entra sem mexer no núcleo" do
      fake = Class.new(Search::Source) do
        def self.call(q, _ctx) = match?(q, "manual da casa") ? [ Search::Result.new(kind: "Ajuda", title: "Manual da casa", icon: "book-open", url: "/manual") ] : []
      end
      stub_const("Search::AjudaSource", fake)
      stub_const("Search::SOURCES", Search::SOURCES + %w[AjudaSource])
      get "/busca", params: { q: "manual" }, headers: { "Turbo-Frame" => "palette-results" }
      expect(response.body).to include("Manual da casa", "Ajuda", 'href="/manual"')
    end
  end

  describe "temas" do
    it "galeria no editor, tema por painel e visão, noite pelo horário do local" do
      get "/paineis/#{dashboard.id}/editar"
      expect(response.body).to include("Aparência", "Aurora", "Tema desta visão", 'name="theme[key]"')

      patch "/paineis/#{dashboard.id}/rascunho", params: { op: "theme", view_id: "home", theme: { key: "aurora", night: "grafite", blur: "12", glass: "0" } }
      draft = within(tenant) { dashboard.reload.draft }
      expect(draft["theme"]).to eq("key" => "aurora", "night" => "grafite", "blur" => 12, "glass" => false)
      v = draft["views"].first["id"]
      patch "/paineis/#{dashboard.id}/rascunho", params: { op: "theme", target: v, view_id: v, theme: { key: "oceano" } }
      draft = within(tenant) { dashboard.reload.draft }
      expect(draft["views"].first["theme"]).to eq("key" => "oceano")

      noon = Time.zone.parse("2026-11-01 15:00 UTC") # 12h em São Paulo
      night = Time.zone.parse("2026-11-01 23:30 UTC")
      expect(Dashboards::Themes.resolve(draft, draft["views"].first, site, now: noon)["theme"]).to eq(Dashboards::Themes::Oceano)
      expect(Dashboards::Themes.resolve(draft, draft["views"].last, site, now: night)).to include("theme" => Dashboards::Themes::Grafite, "night" => true, "glass" => false)

      within(tenant) { dashboard.reload.publish! }
      travel_to(noon) { get "/paineis/#{dashboard.id}" }
      expect(response.body).to include("dw-themed dw-theme-oceano", "--accent: #0284c7")

      bad = draft.merge("theme" => { "key" => "nao-existe", "image" => "javascript:x", "blur" => 99 })
      expect(Dashboards::Schema.errors(bad).join).to include("não existe", "papel de parede", "blur")
    end

    it "tema novo por stub_const aparece na galeria e vale no painel" do
      fake = Class.new(Dashboards::Themes::Base) { describe key: "teste-mar", label: "Teste Mar", accent: "#123456", accent2: "#abcdef", glass: true }
      stub_const("Dashboards::Themes::TesteMar", fake)
      stub_const("Dashboards::Themes::PLUGINS", Dashboards::Themes::PLUGINS + %w[TesteMar])
      get "/paineis/#{dashboard.id}/editar"
      expect(response.body).to include("Teste Mar")
      patch "/paineis/#{dashboard.id}/rascunho", params: { op: "theme", view_id: "home", theme: { key: "teste-mar" } }
      within(tenant) { dashboard.reload.publish! }
      get "/paineis/#{dashboard.id}"
      expect(response.body).to include("dw-theme-teste-mar dw-glass", "--accent: #123456")
      expect { Class.new(Dashboards::Themes::Base) { describe key: "x", label: "X", accent: "red;}", accent2: "#000000" } }.to raise_error(ArgumentError)
    end
  end
end
