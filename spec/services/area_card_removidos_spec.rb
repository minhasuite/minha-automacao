require "rails_helper"

# Card da área: aparelho removido da conta (varredura) ou desativado não conta
# como "sem sinal" (10/11/2026: tomada do ar queimada, apagada da Tuya).
RSpec.describe Dashboards::Widgets::AreaCardWidget do
  let(:tenant) { create(:tenant) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  it "conta só pontos de aparelhos ativos" do
    site = create(:site)
    area = create(:area, site: site, name: "Escritório")
    live = create(:device, site: site, area: area)
    gone = create(:device, site: site, area: area, removed_at: Time.current)
    off = create(:device, site: site, area: area, disabled: true)
    create(:point, device: live, quality: "unavailable")
    create(:point, device: live, name: "Desligado à mão", quality: "unavailable", disabled: true)
    create(:point, device: gone, quality: "unavailable")
    create(:point, device: off, quality: "unavailable")
    dashboard = site.dashboards.create!(name: "P", kind: "custom", definition: { "schema_version" => 1, "views" => [
      { "id" => "v", "title" => "T", "sections" => [ { "id" => "s", "widgets" => [ { "id" => "a", "type" => "area_card", "area" => area.id } ] } ] }
    ] })
    w = Dashboards::Resolver.new(dashboard, role: "owner").call["views"][0]["sections"][0]["widgets"][0]
    expect(w["data"]).to include("unavailable" => 1, "total" => 1)
  end
end
