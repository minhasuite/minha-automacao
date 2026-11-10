require "rails_helper"

RSpec.describe "Web: locais, áreas, dispositivos e pontos" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  it "do Início vazio ao ponto virtual ligado pela tela" do
    sign_in
    get "/"
    expect(response).to redirect_to("/primeira-configuracao") # produto: assistente primeiro
    Onboarding.finish!(tenant)
    get "/"
    expect(response.body).to include("Criar meu primeiro local")
    get "/locais"
    expect(response.body).to include("Nenhum local ainda")
    get "/locais/novo"
    expect(response).to have_http_status(:ok)

    post "/locais", params: { site: { name: "" } }
    expect(response).to have_http_status(:unprocessable_content)
    post "/locais", params: { site: { name: "Casa da Lia", kind: "home" } }
    site = within(tenant) { Site.last }
    expect(response).to redirect_to("/locais/#{site.id}")
    follow_redirect!
    expect(response.body).to include("Criar a primeira área")

    get "/locais/#{site.id}/areas/novo"
    post "/locais/#{site.id}/areas", params: { area: { name: "Sala", kind: "room" } }
    area = within(tenant) { Area.last }
    expect(response).to redirect_to("/areas/#{area.id}")

    get "/locais/#{site.id}/dispositivos/novo", params: { area_id: area.id }
    expect(response.body).to include("Sala")
    post "/locais/#{site.id}/dispositivos", params: { device: { name: "Interruptor", area_id: area.id, driver: "virtual" } }
    device = within(tenant) { Device.last }
    expect(response).to redirect_to("/dispositivos/#{device.id}")

    get "/dispositivos/#{device.id}/pontos/novo"
    post "/dispositivos/#{device.id}/pontos", params: { point: { name: "Luz", capability: "enum", options_text: "" } }
    expect(response).to have_http_status(:unprocessable_content)
    post "/dispositivos/#{device.id}/pontos", params: { point: { name: "Luz", capability: "onoff" } }
    point = within(tenant) { Point.last }
    post "/dispositivos/#{device.id}/pontos", params: { point: { name: "Modo", capability: "enum", options_text: "Casa, Fora" } }
    post "/dispositivos/#{device.id}/pontos", params: { point: { name: "Volume", capability: "setpoint", min: 0, max: 10 } }
    post "/dispositivos/#{device.id}/pontos", params: { point: { name: "Recado", capability: "text" } }
    post "/dispositivos/#{device.id}/pontos", params: { point: { name: "Campainha", capability: "command" } }
    post "/dispositivos/#{device.id}/pontos", params: { point: { name: "Temperatura", capability: "measure", unit: "°C" } }
    post "/dispositivos/#{device.id}/pontos", params: { point: { name: "Cor", capability: "climate" } }

    get "/areas/#{area.id}"
    expect(response.body).to include("Luz", "Ligar", "Casa", "Aplicar", "Acionar", "Sem valor", "chega com os drivers")

    post "/pontos/#{point.id}/comando", params: { command: "on" }, headers: { "Turbo-Frame" => "point_#{point.id}" }
    expect(response.body).to include(%(id="point_#{point.id}"), "Ligado", "Desligar")
    expect(point.reload.value).to be true

    volume = within(tenant) { Point.find_by(name: "Volume") }
    post "/pontos/#{volume.id}/comando", params: { command: "set", value: "50" }, headers: { "Turbo-Frame" => "point_#{volume.id}" }
    expect(response.body).to include("Valor fora da faixa")
    post "/pontos/#{volume.id}/comando", params: { command: "set", value: "7" }
    expect(response).to redirect_to("/dispositivos/#{device.id}")
    expect(volume.reload.value).to eq(7.0)

    get "/dispositivos/#{device.id}"
    expect(response.body).to include("7", "Novo ponto")
    get "/locais/#{site.id}"
    expect(response.body).to include("Sala", "1 dispositivo")
    get "/"
    expect(response.body).to include("Casa da Lia", "Ligados agora")
    get "/locais"
    expect(response.body).to include("Casa da Lia")
  end

  it "edita e exclui local, área, dispositivo e ponto" do
    point = within(tenant) { create(:point, device: create(:device, area: create(:area))) }
    device = point.device
    area = device.area
    site = area.site
    sign_in

    %W[/locais/#{site.id}/editar /areas/#{area.id}/editar /dispositivos/#{device.id}/editar /pontos/#{point.id}/editar].each do |path|
      get path
      expect(response).to have_http_status(:ok)
    end
    patch "/locais/#{site.id}", params: { site: { name: "Sítio" } }
    expect(site.reload.name).to eq("Sítio")
    patch "/locais/#{site.id}", params: { site: { name: "" } }
    expect(response).to have_http_status(:unprocessable_content)
    patch "/areas/#{area.id}", params: { area: { name: "Cozinha" } }
    expect(area.reload.name).to eq("Cozinha")
    patch "/areas/#{area.id}", params: { area: { kind: "x" } }
    expect(response).to have_http_status(:unprocessable_content)
    patch "/dispositivos/#{device.id}", params: { device: { name: "Relé" } }
    expect(device.reload.name).to eq("Relé")
    patch "/dispositivos/#{device.id}", params: { device: { driver: "x" } }
    expect(response).to have_http_status(:unprocessable_content)
    patch "/pontos/#{point.id}", params: { point: { name: "Abajur", risk: "critical" } }
    expect(point.reload).to have_attributes(name: "Abajur", risk: "critical")
    patch "/pontos/#{point.id}", params: { point: { risk: "x" } }
    expect(response).to have_http_status(:unprocessable_content)

    delete "/pontos/#{point.id}"
    expect(response).to redirect_to("/dispositivos/#{device.id}")
    delete "/dispositivos/#{device.id}"
    expect(response).to redirect_to("/areas/#{area.id}")
    delete "/areas/#{area.id}"
    expect(response).to redirect_to("/locais/#{site.id}")
    delete "/locais/#{site.id}"
    expect(response).to redirect_to("/locais")
    expect(within(tenant) { Site.count }).to eq(0)
  end

  it "visitante só vê e comanda o permitido; outra empresa não vê" do
    point = within(tenant) { create(:point, risk: "critical", confirm: "Disparar a sirene?") }
    site = point.site
    guest = create(:user, tenant: tenant, role: "member")
    within(tenant) { create(:site_membership, site: site, user: guest, role: "guest") }
    sign_in(guest)

    get "/"
    expect(response.body).not_to include("Criar meu primeiro local")
    get "/locais"
    expect(response.body).not_to include("Novo local")
    get "/locais/novo"
    expect(response).to redirect_to("/locais")
    get "/dispositivos/#{point.device_id}"
    # Só a tela (o main): o "Falar com a casa" do layout traz o exemplo "Ligar a luz da sala".
    expect(Nokogiri::HTML(response.body).at_css("main").to_html).not_to include("Ligar", "Novo ponto")
    post "/pontos/#{point.id}/comando", params: { command: "on" }
    expect(flash[:alert]).to include("não permite")
    expect(point.reload.value).to be_nil
    get "/locais/#{site.id}/editar"
    expect(response).to redirect_to("/")

    sign_in(create(:user))
    get "/locais/#{site.id}"
    expect(response).to have_http_status(:not_found)
  end
end
