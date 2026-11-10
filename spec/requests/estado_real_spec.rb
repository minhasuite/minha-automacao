require "rails_helper"

# Estado real dos sensores (10/11/2026, portão "aberto" por horas): conferência
# periódica da nuvem Tuya, "Redefinir estado" à mão (técnico+, auditado) e o
# sensor parado em "aberto" que vira "desatualizado" com um aviso só.
RSpec.describe "Estado real dos sensores (web e API)" do
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }
  let(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Sensor do portão", driver: "tuya_cloud", external_id: "door") } }
  let(:door) do
    within(tenant) do
      create(:point, device: device, name: "Abertura do portão", capability: "contact", writable: false, address: { "dps" => "1", "code" => "doorcontact_state" })
    end
  end
  let(:lamp) { within(tenant) { create(:point, device: device, name: "Luz") } }

  around { |ex| within(tenant) { ex.run } }

    def sign_in(u = owner) = post("/entrar", params: { email: u.email, password: "12345678" })

    it "página do ponto mostra o Redefinir para técnico+ e redefine" do
      sign_in
      door.report!(true)
      get "/pontos/#{door.id}"
      expect(response.body).to include("Redefinir estado", "/pontos/#{door.id}/redefinir")
      post "/pontos/#{door.id}/redefinir", params: { value: "false" }
      expect(response).to redirect_to("/pontos/#{door.id}")
      expect(door.reload.value).to be false

      get "/pontos/#{lamp.id}"
      expect(response.body).not_to include("/redefinir")
      post "/pontos/#{lamp.id}/redefinir", params: { value: "true" }
      expect(flash[:alert]).to be_present
    end

    it "morador não redefine; campo do limite no formulário do sensor" do
      resident = create(:user, tenant: tenant, role: "member")
      SiteMembership.create!(site: site, user: resident, role: "resident")
      sign_in(resident)
      get "/pontos/#{door.id}"
      expect(response.body).not_to include("/redefinir")
      post "/pontos/#{door.id}/redefinir", params: { value: "false" }
      expect(door.reload.value).not_to be false

      sign_in
      get "/pontos/#{door.id}/editar"
      expect(response.body).to include("point[stale_open_min]")
      patch "/pontos/#{door.id}", params: { point: { stale_open_min: "30" } }
      expect(door.reload.address["stale_open_s"]).to eq(1800)
    end

    it "API: POST /points/:id/reset" do
      post "/api/v1/points/#{door.id}/reset", params: { value: "true" }, headers: auth_headers(owner)
      expect(response).to have_http_status(:ok)
      expect(door.reload.value).to be true
      post "/api/v1/points/#{lamp.id}/reset", params: { value: "true" }, headers: auth_headers(owner)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json.dig("error", "code")).to eq("not_resettable")
    end
end
