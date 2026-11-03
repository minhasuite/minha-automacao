require "rails_helper"

RSpec.describe "Notificações, push, IA e páginas públicas" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let(:headers) { auth_headers(user) }

  describe "notificações" do
    it "lista, marca uma e marca todas" do
      n1, = within(tenant) { [ create(:notification, title: "A"), create(:notification, title: "B", user: user) ] }
      member = create(:user, tenant: tenant, role: "member")
      get "/api/v1/notifications", headers: auth_headers(member)
      expect(data).to eq([]) # aviso sem dono é dos administradores
      get "/api/v1/notifications", headers: headers
      expect(json["meta"]["unread_count"]).to eq(2)
      patch "/api/v1/notifications/#{n1.id}/read", headers: headers
      expect(data["read_at"]).to be_present
      get "/api/v1/notifications", params: { unread: true }, headers: headers
      expect(data.size).to eq(1)
      patch "/api/v1/notifications/read", headers: headers
      expect(data).to include("marked" => 1, "unread_count" => 0)
    end
  end

  describe "device tokens" do
    it "registra (reatribuindo) e remove" do
      other = create(:user)
      DeviceToken.create!(user: other, token: "fcm:abc.123")
      post "/api/v1/device_tokens", params: { token: "fcm:abc.123", platform: "android" }, headers: headers
      expect(response).to have_http_status(:created)
      expect(DeviceToken.find_by(token: "fcm:abc.123").user).to eq(user)
      delete "/api/v1/device_tokens/fcm:abc.123", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(DeviceToken.count).to eq(0)
    end
  end

  describe "IA" do
    it "mostra a cota por feature" do
      get "/api/v1/ai/quota", headers: headers
      expect(data).to include("enabled" => false, "plan" => "free")
      enable_ai!
      within(tenant) { AiUsage.record!("ask") }
      get "/api/v1/ai/quota", headers: headers
      expect(data["features"]["ask"]).to include("available" => false, "limit" => nil)
      expect(data["daily"]).to include("limit" => 0)
      tenant.update!(plan: "pro")
      get "/api/v1/ai/quota", headers: headers
      expect(data["features"]["ask"]).to include("available" => true, "limit" => 300, "used" => 1, "remaining" => 299)
      expect(data["daily"]).to include("limit" => 80)
    end

    it "pergunta à IA (administrador), debitando a cota" do
      enable_ai!
      tenant.update!(plan: "pro")
      stub_ai({ answer: "Desligue o que não usa." })
      post "/api/v1/ai/ask", params: { question: "como economizar?" }, headers: headers
      expect(data).to eq("answer" => "Desligue o que não usa.")
      expect(within(tenant) { AiUsage.count_for("ask") }).to eq(1)
      post "/api/v1/ai/ask", params: { question: "x" }, headers: auth_headers(create(:user, tenant: tenant, role: "member"))
      expect(response).to have_http_status(:forbidden)
    end

    it "IA fora do ar vira 503" do
      enable_ai!
      tenant.update!(plan: "pro")
      allow(Ai::Client).to receive(:new).and_return(instance_double(Ai::Client).tap { |c| allow(c).to receive(:complete).and_raise(Ai::Client::Error, "caiu") })
      post "/api/v1/ai/ask", params: { question: "x" }, headers: headers
      expect(response).to have_http_status(:service_unavailable)
    end
  end

  it "páginas legais em pt e en" do
    %w[/privacidade /termos /exclusao /privacy /terms /data-deletion].each do |path|
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Minha Automação")
    end
  end

  it "páginas legais falam de casa/instalação, não de empresa, nos três idiomas" do
    files = Dir[Rails.root.join("app/views/legal/{privacy,terms,data_deletion}*.html.erb")]
    expect(files.size).to eq(9)
    files.each { |f| expect(File.read(f)).not_to match(/empresa|company/i), f }
  end

  it "páginas legais no idioma pedido, em qualquer ordem (pt-BR não cai no .en do fallback)" do
    h1 = { "pt-BR" => "Exclusão de dados", "en" => "Data deletion", "es" => "Eliminación de datos" }
    %w[pt-BR en es pt-BR es en pt-BR].each do |lang|
      get "/exclusao", headers: { "Accept-Language" => lang }
      expect(response.body).to include("<html lang=\"#{lang}\">", "<h1>#{h1[lang]}</h1>")
    end
    get "/exclusao", headers: { "Accept-Language" => "pt-BR" }
    expect(response.body).to include("dados da sua casa")
  end

  it "healthcheck" do
    get "/up"
    expect(response).to have_http_status(:ok)
  end
end
