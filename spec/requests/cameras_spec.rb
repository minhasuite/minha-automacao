require "rails_helper"

RSpec.describe "Câmeras: proxy do go2rtc com autorização do local" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let!(:camera) do
    within(tenant) do
      d = create(:device, site: site, driver: "go2rtc", name: "Câmera", address: { "host" => "192.168.0.12" })
      create(:point, device: d, name: "Quintal", capability: "stream", address: { "path" => "/live" })
    end
  end
  let(:base) { "http://go2rtc:1984" }

  around do |ex|
    old = ENV.fetch("GO2RTC_URL", nil)
    ENV["GO2RTC_URL"] = "http://go2rtc:1984"
    ex.run
  ensure
    ENV["GO2RTC_URL"] = old
    FileUtils.rm_rf(Drivers::Go2rtc::SNAPSHOT_DIR)
  end

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  it "sem login vai para a entrada; de outra empresa não acha" do
    get "/cameras/#{camera.id}/quadro"
    expect(response.location).to include("/entrar")
    stranger = create(:user)
    sign_in(stranger)
    get "/cameras/#{camera.id}/quadro"
    expect(response).to have_http_status(:not_found)
  end

  it "membro sem papel no local não vê; visitante vê o quadro" do
    member = create(:user, tenant: tenant, role: "member")
    sign_in(member)
    get "/cameras/#{camera.id}/quadro"
    expect(response).to have_http_status(:not_found)

    within(tenant) { create(:site_membership, site: site, user: member, role: "guest") }
    stub_request(:get, "#{base}/api/frame.jpeg?src=#{camera.id}").to_return(body: "JPEG")
    get "/cameras/#{camera.id}/quadro"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/jpeg")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body).to eq("JPEG")
  end

  it "ponto que não é câmera não passa pelo proxy" do
    sign_in
    other = within(tenant) { create(:point, device: camera.device, name: "Luz") }
    get "/cameras/#{other.id}/quadro"
    expect(response).to have_http_status(:not_found)
  end

  it "go2rtc fora do ar: 503 com o motivo" do
    sign_in
    stub_request(:get, "#{base}/api/frame.jpeg?src=#{camera.id}").to_raise(Errno::ECONNREFUSED)
    get "/cameras/#{camera.id}/quadro"
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).to include("fora do ar")
  end

  it "ao vivo: repassa a oferta SDP e devolve a resposta" do
    sign_in
    stub_request(:post, "#{base}/api/webrtc?src=#{camera.id}").with(body: "v=0 oferta").to_return(body: "v=0 resposta")
    post "/cameras/#{camera.id}/ao-vivo", params: "v=0 oferta", headers: { "CONTENT_TYPE" => "application/sdp" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("v=0 resposta")
    post "/cameras/#{camera.id}/ao-vivo", params: "", headers: { "CONTENT_TYPE" => "application/sdp" }
    expect(response).to have_http_status(:unprocessable_content)
    ENV["GO2RTC_URL"] = nil
    post "/cameras/#{camera.id}/ao-vivo", params: "v=0 oferta", headers: { "CONTENT_TYPE" => "application/sdp" }
    expect(response).to have_http_status(:service_unavailable)
  end

  it "o painel mostra o widget de câmera" do
    sign_in
    get "/"
    expect(response.body).to include("Câmeras", 'data-controller="camera ss-camera"', "/cameras/#{camera.id}/quadro", "Ao vivo")
  end

  describe "ao vivo automático (autoplay)" do
    def painel(widget)
      within(tenant) do
        Dashboard.create!(site: site, name: "Câmeras", kind: "custom", site_default: true,
                          definition: { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => [ widget ] } ] } ] })
      end
    end

    it "o card leva o autoplay e o limite nos data-attributes; sem autoplay, desligado" do
      sign_in
      d = painel({ "id" => "c1", "type" => "camera", "bind" => camera.id, "autoplay" => true, "autoplay_max" => 3 })
      get "/paineis/#{d.id}"
      card = Nokogiri::HTML(response.body).at_css("[data-controller~='camera']")
      expect(card["data-camera-autoplay-value"]).to eq("true")
      expect(card["data-camera-autoplay-max-value"]).to eq("3")

      within(tenant) { d.update!(definition: d.definition.deep_merge("views" => [ d.definition["views"].first.merge("sections" => [ { "id" => "s", "widgets" => [ { "id" => "c1", "type" => "camera", "bind" => camera.id } ] } ]) ])) }
      get "/paineis/#{d.id}"
      card = Nokogiri::HTML(response.body).at_css("[data-controller~='camera']")
      expect(card["data-camera-autoplay-value"]).to eq("false")
      expect(card["data-camera-autoplay-max-value"]).to eq(Dashboards::Widgets::CameraWidget::AUTOPLAY_MAX.to_s)
    end

    it "Schema e JSON Schema validam autoplay e autoplay_max" do
      ok = { "id" => "c1", "type" => "camera", "bind" => camera.id, "autoplay" => true, "autoplay_max" => 8 }
      defn = ->(w) { { "schema_version" => 1, "views" => [ { "id" => "v", "title" => "V", "sections" => [ { "id" => "s", "widgets" => [ w ] } ] } ] } }
      expect(Dashboards::Schema.errors(defn.(ok))).to eq([])
      errs = Dashboards::Schema.errors(defn.(ok.merge("autoplay" => "sim", "autoplay_max" => 40)))
      expect(errs.join).to include("autoplay", "autoplay_max")
      props = Dashboards::JsonSchema.call.dig("$defs", "widget_camera", "properties") || Dashboards::JsonSchema.call.to_json
      expect(props.to_json).to include("autoplay_max")
    end

    it "editor: caixa \"Ao vivo automático\" grava autoplay e editar não perde o intervalo" do
      sign_in
      d = painel({ "id" => "c1", "type" => "camera", "bind" => camera.id, "snapshot_interval" => 30 })
      within(tenant) { d.update!(draft: d.definition) }
      get "/paineis/#{d.id}/editar"
      expect(response.body).to include("Ao vivo automático")
      patch "/paineis/#{d.id}/rascunho", params: { op: "update_widget", target: "c1", view_id: "v", widget: { type: "camera", bind: camera.id, autoplay: "1" } }
      w = within(tenant) { d.reload.draft["views"].first["sections"].first["widgets"].first }
      expect(w).to include("autoplay" => true, "live" => true, "snapshot_interval" => 30)
      patch "/paineis/#{d.id}/rascunho", params: { op: "update_widget", target: "c1", view_id: "v", widget: { type: "camera", bind: camera.id, autoplay: "0" } }
      expect(within(tenant) { d.reload.draft["views"].first["sections"].first["widgets"].first }).not_to have_key("autoplay")
    end
  end
end
