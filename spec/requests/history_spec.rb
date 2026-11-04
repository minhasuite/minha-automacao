require "rails_helper"

RSpec.describe "Histórico na API e na web" do
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }
  let(:headers) { auth_headers(owner) }
  let(:device) { within(tenant) { create(:device) } }
  let(:lamp) { within(tenant) { create(:point, device: device, name: "Luz") } }
  let(:temp) { within(tenant) { create(:point, device: device, name: "Temperatura", capability: "measure", unit: "°C") } }

  def add(point, at, value) = Reading.insert_all!([ { point_id: point.id, at: at, value: value } ], returning: false)

  it "devolve leituras cruas com o valor vigente no início e rollups em janela longa" do
    add(temp, 3.hours.ago, 19)
    add(temp, 1.hour.ago, 21)
    get "/api/v1/points/#{temp.id}/history", params: { from: 2.hours.ago.iso8601 }, headers: headers
    expect(json["meta"]).to include("resolution" => "raw", "truncated" => false)
    expect(data.pluck("value")).to eq([ 19.0, 21.0 ])

    RollupReadingsJob.perform_now
    get "/api/v1/points/#{temp.id}/history", params: { from: 7.days.ago.iso8601 }, headers: headers
    expect(json["meta"]["resolution"]).to eq("1h")
    expect(data.last).to include("avg" => 21.0, "count" => 1)
    get "/api/v1/points/#{temp.id}/history", params: { from: 60.days.ago.iso8601, resolution: "1d" }, headers: headers
    expect(json["meta"]["resolution"]).to eq("1d")

    get "/api/v1/points/#{temp.id}/history", params: { resolution: "5m" }, headers: headers
    expect(response).to have_http_status(:bad_request)
    get "/api/v1/points/#{temp.id}/history", params: { from: 1.hour.from_now.iso8601 }, headers: headers
    expect(json.dig("error", "code")).to eq("invalid_parameter")
    get "/api/v1/points/#{temp.id}/history", headers: auth_headers(create(:user))
    expect(response).to have_http_status(:not_found)
  end

  it "comando de outra empresa não aparece" do
    cmd = within(tenant) { Command.create!(site: lamp.site, point: lamp, command: "on", source: "api") }
    get "/api/v1/commands/#{cmd.id}", headers: auth_headers(create(:user))
    expect(response).to have_http_status(:not_found)
  end

  describe "página do ponto" do
    before do
      post "/entrar", params: { email: owner.email, password: "12345678" }
    end

    it "mostra o gráfico de faixas, o tempo ligado e quem comandou" do
      post "/pontos/#{lamp.id}/comando", params: { command: "on" }
      within(tenant) { lamp.reload.report!(true, quality: "unavailable") }
      get "/pontos/#{lamp.id}"
      expect(response.body).to include("Histórico", "Ligado por", "ss-time-chart", "ss-tc-bands", "Ligar", "por #{owner.name}", "pelo web", "Ficou indisponível",
                                       "Ponto criado", "turbo-cable-stream-source", "PointsChannel")
      get "/pontos/#{lamp.id}", params: { range: "7d" }
      expect(response.body).to include(%(aria-current="true"))
    end

    it "linha para número, faixa mín–máx nos rollups e aviso sem dado" do
      get "/pontos/#{temp.id}"
      expect(response.body).to include("Sem leituras neste período")
      add(temp, 2.hours.ago, 19)
      add(temp, 1.hour.ago, 23.5)
      get "/pontos/#{temp.id}"
      # Gráfico da gem: os pontos vão em JSON para o ss-time-chart desenhar.
      expect(response.body).to include("ss-time-chart", ",23.5]")
      RollupReadingsJob.perform_now
      get "/pontos/#{temp.id}", params: { range: "30d" }
      expect(response.body).to match(/\[\d{13},[\d.]+,[\d.]+,[\d.]+\]/) # rollup: [t, média, mín, máx]
      mode = within(tenant) { create(:point, device: device, capability: "enum", options: %w[Casa]) }
      get "/pontos/#{mode.id}"
      expect(response.body).to include("não tem gráfico")
    end

    it "comando que falha mostra o erro no cartão" do
      allow_any_instance_of(Drivers::Virtual).to receive(:execute).and_raise(IOError, "sem resposta") # rubocop:disable RSpec/AnyInstance
      post "/pontos/#{lamp.id}/comando", params: { command: "on" }, headers: { "Turbo-Frame" => "point_#{lamp.id}" }
      expect(response.body).to include("sem resposta")
    end
  end
end
