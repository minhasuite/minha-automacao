require "rails_helper"

# appweb (Onda D do app): tag NFC/QR lida no celular dispara o gatilho "Tag
# lida" (D4) e os sensores novos do Android (D1) entram pelo registro
# `MobileAppPlugin::SENSORS` (sensor falso por stub_const, sem mudar o núcleo).
RSpec.describe "App do celular: tags e sensores (appweb D1/D4)" do
  let(:user) { create(:user, name: "Teste Ana") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Teste Casa") } }
  let(:h) { auth_headers(user) }

  def phone
    post "/api/v1/sites/#{site.id}/mobile_devices", params: { install_id: "teste-appweb-1", name: "Teste Pixel" }, headers: h
    response.parsed_body.dig("data", "id")
  end

  def automation(trigger)
    within(tenant) do
      Automation.create!(site: site, name: "Teste tag #{SecureRandom.hex(2)}").tap do |a|
        a.publish!({ "triggers" => [ trigger ], "actions" => [ { "type" => "notify", "channels" => [ "in_app" ], "title" => "{{ trigger.user }} leu {{ trigger.tag }} no {{ trigger.device }}" } ] })
        a.update!(enabled: true)
      end
    end
  end

  it "tag lida dispara só a automação daquela tag (ou de qualquer tag)" do
    porta = automation({ "type" => "tag", "tag" => "porta-entrada" })
    qualquer = automation({ "type" => "tag" })
    outra = automation({ "type" => "tag", "tag" => "garagem" })
    id = phone
    perform_enqueued_jobs { post "/api/v1/mobile_devices/#{id}/tag", params: { tag: "porta-entrada" }, headers: h }
    expect(response).to have_http_status(:ok)
    within(tenant) do
      expect(porta.runs.count).to eq(1)
      expect(qualquer.runs.count).to eq(1)
      expect(outra.runs.count).to eq(0)
      expect(Notification.where(title: "Teste Ana leu porta-entrada no Teste Pixel")).to exist
    end
    expect(Automations::TriggerTypes::TagTrigger.title({ "tag" => "x" })).to eq("Tag lida (x)")
  end

  it "recusa tag inválida e celular de outra pessoa" do
    id = phone
    post "/api/v1/mobile_devices/#{id}/tag", params: { tag: "a b/c" }, headers: h
    expect(response).to have_http_status(:bad_request)
    other = create(:user, tenant: tenant, role: "member")
    post "/api/v1/mobile_devices/#{id}/tag", params: { tag: "porta" }, headers: auth_headers(other)
    expect(response).to have_http_status(:not_found)
  end

  it "sensores novos do Android viram pontos; sensor novo é só uma entrada no registro" do
    fake = { name: "Teste Passos", capability: "measure", unit: "passos", read: ->(v, _i) { v.to_i } }
    stub_const("Integrations::MobileAppPlugin::SENSORS", Integrations::MobileAppPlugin::SENSORS.merge("teste_passos" => fake))
    id = phone
    post "/api/v1/mobile_devices/#{id}/sensors", params: { dnd: true, ringer: "vibrar", volume: 40, storage_free: 12.34, next_alarm: "2026-11-03T06:30:00-03:00",
                                                           network: "wifi", interactive: false, power_save: true, teste_passos: 4321 }, headers: h
    expect(response).to have_http_status(:ok)
    values = response.parsed_body.dig("data", "points").to_h { |p| [ p["name"], p["value"] ] }
    expect(values).to include("Não perturbe" => true, "Modo da campainha" => "vibrar", "Volume da mídia" => 40, "Armazenamento livre" => 12.3,
                              "Próximo alarme" => "2026-11-03T06:30:00-03:00", "Rede" => "wifi", "Tela ligada" => false, "Economia de bateria" => true,
                              "Teste Passos" => 4321)
  end
end
