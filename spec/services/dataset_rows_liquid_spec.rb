require "rails_helper"

# O Texto do painel lendo um conjunto de dados (`dataset_rows`, o sensor `sql`
# do HA) e as versões do servidor nos pontos do Sistema (o `installed_version`
# dos tiles "Core" e "Sistema" do HA).
RSpec.describe "Conjunto de dados no Liquid e versões do Sistema" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, name: "Casa") }

  around { |ex| ActsAsTenant.with_tenant(tenant) { travel_to(Time.zone.parse("2026-11-09 18:00")) { ex.run } } }

  describe "dataset_rows" do
    let(:dashboard) { Dashboard.create!(site: site, name: "Robô", kind: "home", definition: defn([])) }
    let!(:dataset) { Dataset.create!(site: site, name: "Robô histórico") }

    def defn(widgets) = { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => widgets } ] } ] }
    def markdown(text) = Dashboards::Resolver.new(dashboard, role: "owner", definition: defn([ { "id" => "m", "type" => "markdown", "text" => text } ])).call["views"][0]["sections"][0]["widgets"][0]["data"]

    it "lista as linhas mais recentes no fuso do local, com limite e filtro; sem linhas cai no else" do
      text = %({% assign acoes = "robo_historico" | dataset_rows: 2 %}{% for a in acoes %}**{{ a.em | date: "%d/%m %H:%M" }}** · {{ a.acao }}\n{% else %}Nenhuma ação registrada ainda.{% endfor %})
      expect(markdown(text)["text"]).to eq("Nenhuma ação registrada ainda.")

      { "13:23" => [ "Aspirou", "limpeza" ], "14:00" => [ "Parou com erro", "erro" ], "15:42" => [ "Passou pano", "limpeza" ] }.each do |at, (acao, tipo)|
        dataset.record!({ "acao" => acao, "tipo" => tipo }).update_columns(created_at: Time.zone.parse("2026-11-09 #{at}"))
      end

      expect(markdown(text)["text"]).to eq("**09/11 15:42** · Passou pano\n**09/11 14:00** · Parou com erro\n")
      only_errors = %({% assign e = "robo_historico" | dataset_rows: 10, "tipo = erro" %}{{ e.size }} {{ e.first.acao }})
      expect(markdown(only_errors)["text"]).to eq("1 Parou com erro")
    end

    it "conjunto que não existe ou filtro inválido viram o erro do card" do
      expect(markdown(%({{ "nada" | dataset_rows | size }}))["error"]).to include("conjunto de dados \"nada\" não existe")
      expect(markdown(%({{ "robo_historico" | dataset_rows: 5, "tipo ~ x" | size }}))["error"]).to be_present
    end

    it "serve também aos textos das automações" do
      dataset.record!({ "acao" => "Lavou o pano" })
      ctx = Automations::Context.new(site: site)
      expect(ctx.render(%({{ "robo_historico" | dataset_rows: 1 | map: "acao" | join: "," }}))).to eq("Lavou o pano")
    end
  end

  describe "versões no Sistema" do
    it "versão do Minha Automação e kernel do servidor viram pontos de texto" do
      stub_const("ENV", ENV.to_h.merge("RELEASE_TAG" => "v0.9.0", "APP_VERSION" => "633861fabc"))
      Integrations::SystemPlugin.setup(site, {})
      integration = site.integrations.find_by!(driver: "system")
      points = Integrations::SystemPlugin.device_for(integration).points.index_by { |p| p.address["field"] }
      expect(points["app_version"]).to have_attributes(name: "Versão do Minha Automação", capability: "text", value: "v0.9.0 (633861f)")
      expect(points["kernel"].value).to start_with("Linux ") if File.readable?("/proc/sys/kernel/osrelease")

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "osrelease"), "6.12.96+deb13-amd64\n")
        expect(Integrations::SystemPlugin.kernel(File.join(dir, "osrelease"))).to eq("Linux 6.12.96+deb13-amd64")
      end
      expect(Integrations::SystemPlugin.kernel("/nao/existe")).to be_nil
    end
  end
end
