require "rails_helper"

# F7: o que o app Flutter precisa da API além do que já existia — tempo real
# pelo /cable com o token, resposta aos botões do aviso, quadro da câmera e o
# "App do celular" (sensores do aparelho como pontos).
RSpec.describe "API do app (F7)" do
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }
  let(:headers) { auth_headers(owner) }
  let!(:site) { within(tenant) { create(:site, name: "Casa", latitude: -15.8, longitude: -47.9) } }

  def member(role)
    user = create(:user, tenant: tenant, role: "member")
    within(tenant) { create(:site_membership, site: site, user: user, role: role) } if role
    user
  end

  describe "tempo real" do
    it "o local traz o stream assinado dos pontos" do
      get "/api/v1/sites/#{site.id}", headers: headers
      expect(data["points_stream"]).to eq(Turbo::StreamsChannel.signed_stream_name([ site, :points ]))
    end
  end

  describe "pontos do aparelho como o app desenha" do
    it "?view=app traz texto, comandos e can_command pelo papel" do
      device = within(tenant) { create(:device, site: site, name: "Relé") }
      within(tenant) { create(:point, device: device, site: site, name: "Portão", capability: "onoff", risk: "critical", value: false) }
      get "/api/v1/devices/#{device.id}/points", params: { view: "app" }, headers: auth_headers(member("guest"))
      expect(data.first).to include("name" => "Portão", "text" => be_present, "commands" => include("toggle"), "can_command" => false, "device" => "Relé")
      get "/api/v1/devices/#{device.id}/points", params: { view: "app" }, headers: headers
      expect(data.first["can_command"]).to be(true)
    end
  end

  describe "avisos com botões" do
    let(:notification) do
      within(tenant) do
        Notification.create!(kind: "aviso", title: "Portão aberto", user: owner,
                             data: { "site_id" => site.id, "url" => "/paineis", "actions" => [ { "id" => "fechar", "title" => "Fechar" } ] })
      end
    end

    it "lista com botões e link; responde uma vez; botão inválido é 422" do
      notification
      get "/api/v1/notifications", headers: headers
      expect(data.first).to include("actions" => [ { "id" => "fechar", "title" => "Fechar" } ], "url" => "/paineis", "responded_at" => nil)

      post "/api/v1/notifications/#{notification.id}/respond", params: { action_id: "abrir" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(json.dig("error", "code")).to eq("invalid_action")

      post "/api/v1/notifications/#{notification.id}/respond", params: { action_id: "fechar" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(data).to include("actions" => [], "response_title" => "Fechar", "responded_at" => be_present, "read_at" => be_present)

      post "/api/v1/notifications/#{notification.id}/respond", params: { action_id: "fechar" }, headers: headers
      expect(response).to have_http_status(:conflict)
      expect(json.dig("error", "code")).to eq("already_responded")
    end

    it "aviso de outra pessoa não é encontrado" do
      notification
      post "/api/v1/notifications/#{notification.id}/respond", params: { action_id: "fechar" }, headers: auth_headers(member("guest"))
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "quadro da câmera" do
    let!(:camera) do
      within(tenant) do
        d = create(:device, site: site, driver: "go2rtc", name: "Câmera", address: { "host" => "192.168.0.12" })
        create(:point, device: d, site: site, name: "Quintal", capability: "stream", address: { "path" => "/live" })
      end
    end

    around do |ex|
      old = ENV.fetch("GO2RTC_URL", nil)
      ENV["GO2RTC_URL"] = "http://go2rtc:1984"
      ex.run
    ensure
      ENV["GO2RTC_URL"] = old
      FileUtils.rm_rf(Drivers::Go2rtc::SNAPSHOT_DIR)
    end

    it "JPEG para quem tem papel; 503 com a câmera fora; 404 sem papel ou fora de câmera" do
      stub_request(:get, "http://go2rtc:1984/api/frame.jpeg?src=#{camera.id}").to_return(body: "JPEG")
      get "/api/v1/points/#{camera.id}/snapshot", headers: auth_headers(member("guest"))
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/jpeg")
      expect(response.body).to eq("JPEG")
      expect(response.headers["Cache-Control"]).to include("no-store")

      get "/api/v1/points/#{camera.id}/snapshot", headers: auth_headers(member(nil))
      expect(response).to have_http_status(:not_found)

      lamp = within(tenant) { create(:point, device: camera.device, site: site, name: "Luz", capability: "onoff") }
      get "/api/v1/points/#{lamp.id}/snapshot", headers: headers
      expect(response).to have_http_status(:not_found)

      FileUtils.rm_rf(Drivers::Go2rtc::SNAPSHOT_DIR)
      stub_request(:get, "http://go2rtc:1984/api/frame.jpeg?src=#{camera.id}").to_return(status: 500)
      get "/api/v1/points/#{camera.id}/snapshot", headers: headers
      expect(response).to have_http_status(:service_unavailable)
      expect(json.dig("error", "code")).to eq("camera_unavailable")
    end
  end

  describe "App do celular" do
    let(:guest) { member("guest") }
    let(:guest_headers) { auth_headers(guest) }

    def register(h = guest_headers, install_id: "inst-12345678")
      post "/api/v1/sites/#{site.id}/mobile_devices", params: { install_id: install_id, name: "Celular", model: "Pixel 8", platform: "android" }, headers: h
    end

    def point(device_id, field) = within(tenant) { Device.find(device_id).points.find_by!("address->>'field' = ?", field) }

    it "registra (qualquer papel), recebe os sensores como pontos e calcula a presença" do
      register
      expect(response).to have_http_status(:created)
      expect(data).to include("driver" => "virtual", "name" => "Celular", "manufacturer" => "App do celular", "model" => "Pixel 8", "points" => [])
      device_id = data["id"]
      register # de novo: o mesmo aparelho
      expect(data["id"]).to eq(device_id)
      expect(within(tenant) { site.integrations.find_by!(driver: "mobile_app").poll_s }).to eq(0)

      post "/api/v1/mobile_devices/#{device_id}/sensors", params: { battery: 87.4, charging: true, wifi: "\"Casa\"",
                                                                      location: { latitude: -15.8005, longitude: -47.9, accuracy: 20 } },
                                                           headers: guest_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(data["points"].map { |p| p["name"] }).to contain_exactly("Bateria", "Carregando", "Wi-Fi", "Presença")
      expect(point(device_id, "battery")).to have_attributes(value: 87, unit: "%", device_class: "battery")
      expect(point(device_id, "charging")).to have_attributes(value: true, writable: false)
      expect(point(device_id, "wifi").value).to eq("Casa")
      expect(point(device_id, "location").value).to eq("Em casa")
      expect(point(device_id, "location").attrs).to include("latitude" => -15.8005, "accuracy" => 20, "distance_m" => 56)

      post "/api/v1/mobile_devices/#{device_id}/sensors", params: { charging: false, location: { latitude: -15.9, longitude: -47.9, accuracy: 30 } },
                                                           headers: guest_headers, as: :json
      expect(point(device_id, "location").value).to eq("Fora")
      expect(point(device_id, "charging").value).to be(false)
      expect(point(device_id, "battery").value).to eq(87) # o que não veio fica

      post "/api/v1/mobile_devices/#{device_id}/sensors", params: { location: { latitude: "x" } }, headers: guest_headers, as: :json
      expect(point(device_id, "location").value).to eq("Fora")
    end

    it "só a dona do aparelho manda leitura ou remove; install_id é conferido; sem papel não registra" do
      register
      device_id = data["id"]
      post "/api/v1/mobile_devices/#{device_id}/sensors", params: { battery: 10 }, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)

      register(headers) # outra pessoa no mesmo celular: aparelho próprio
      expect(data["id"]).not_to eq(device_id)

      register(install_id: "x")
      expect(response).to have_http_status(:bad_request)
      register(auth_headers(member(nil)))
      expect(response).to have_http_status(:not_found)

      sensor = within(tenant) { create(:point, site: site, device: create(:device, site: site), name: "Outro") }
      delete "/api/v1/mobile_devices/#{sensor.device_id}", headers: guest_headers
      expect(response).to have_http_status(:not_found)

      delete "/api/v1/mobile_devices/#{device_id}", headers: guest_headers
      expect(response).to have_http_status(:no_content)
      expect(within(tenant) { Device.exists?(device_id) }).to be(false)
    end

    it "local sem coordenadas: sem presença, com os outros sensores" do
      within(tenant) { site.update!(latitude: nil, longitude: nil) }
      register
      device_id = data["id"]
      post "/api/v1/mobile_devices/#{device_id}/sensors", params: { battery: 50, location: { latitude: -15.8, longitude: -47.9 } }, headers: guest_headers, as: :json
      expect(data["points"].map { |p| p["name"] }).to eq([ "Bateria" ])
    end

    it "na web: formulário com o raio, salvar e varredura sem conta" do
      post "/entrar", params: { email: owner.email, password: "12345678" }
      get "/locais/#{site.id}/integracoes/nova", params: { tipo: "mobile_app" }
      expect(response.body).to include("Raio de", "Sensores do celular")
      post "/locais/#{site.id}/integracoes", params: { tipo: "mobile_app", integration: { home_radius_m: "300" } }
      integration = within(tenant) { site.integrations.find_by!(driver: "mobile_app") }
      expect(integration.settings).to include("home_radius_m" => 300, "account" => "Celulares com o app")
      within(tenant) do
        Integrations::MobileAppPlugin.login(integration, { home_radius_m: "1" })
        expect(integration.reload.settings["home_radius_m"]).to eq(150)
        expect(Integrations.sync!(integration)).to include(found: 0)
        expect(Integrations::MobileAppPlugin.presence(integration, { "latitude" => -15.8025, "longitude" => -47.9 })).to eq("Fora")
        integration.update!(settings: integration.settings.merge("home_radius_m" => 300))
        expect(Integrations::MobileAppPlugin.presence(integration, { "latitude" => -15.8025, "longitude" => -47.9 })).to eq("Em casa")
      end
    end
  end
end
