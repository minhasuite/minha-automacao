require "rails_helper"

# Onda A2 (paridade HA, grupo 7): sistema.
RSpec.describe "Onda A2: sistema" do
  let(:user) { create(:user, role: "owner") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Medidor") } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  describe "A14 ferramenta de estatísticas" do
    let!(:meter) { within(tenant) { create(:point, site: site, device: device, name: "Teste Energia", capability: "measure", unit: "kWh") } }
    let!(:old) { within(tenant) { create(:point, site: site, device: device, name: "Teste Antigo", capability: "measure", history: "none") } }
    let(:hour) { Time.zone.parse("2026-10-10 14:00") }

    before do
      [ hour, hour + 1.hour ].each { |h| ReadingRollup.insert_all([ { point_id: meter.id, bucket: "1h", starts_at: h, sum: 2, count: 1, min: 2, max: 2, avg: 2, last: 2 } ]) }
      ReadingRollup.insert_all([ { point_id: old.id, bucket: "1h", starts_at: hour, sum: 1, count: 1 } ])
      RollupReadingsJob.new.daily(hour.beginning_of_day, hour.end_of_day)
      sign_in
    end

    it "lista, aponta o órfão, ajusta a soma (refaz o dia) e apaga" do
      get "/locais/#{site.id}/ferramentas", params: { aba: "estatisticas" }
      expect(response.body).to include("Teste Energia", "Teste Antigo", "Não grava mais", "2 h")
      expect(within(tenant) { DevTools::Statistics.list(site) }.map(&:issue)).to contain_exactly(nil, "orphan")

      post "/locais/#{site.id}/ferramentas/estatisticas", params: { point_id: meter.id, at: "2026-10-10T14:00", sum: "5,5" }
      expect(flash[:notice]).to include("ajustada")
      day = ReadingRollup.find_by(point_id: meter.id, bucket: "1d")
      expect(day.sum.to_f).to eq(7.5)

      post "/locais/#{site.id}/ferramentas/estatisticas", params: { point_id: meter.id, at: "2026-10-09T03:00", sum: "1" }
      expect(flash[:alert]).to eq("Não há resumo nessa hora.")

      delete "/locais/#{site.id}/ferramentas/estatisticas/#{old.id}"
      expect(ReadingRollup.where(point_id: old.id)).to be_empty
      expect(ReadingRollup.where(point_id: meter.id).count).to eq(3)
    end

    it "membro comum não vê" do
      member = within(tenant) { create(:user, tenant: tenant, role: "member") }
      sign_in(member)
      delete "/locais/#{site.id}/ferramentas/estatisticas/#{old.id}"
      expect(response).to have_http_status(:not_found)
      expect(ReadingRollup.where(point_id: old.id)).to exist
    end
  end
end
