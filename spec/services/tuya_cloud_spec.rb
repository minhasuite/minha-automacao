require "rails_helper"

# Nuvem da Tuya (Smart Life) com um servidor falso que confere a assinatura e
# cifra as respostas do mesmo jeito do tuya-device-sharing-sdk.
RSpec.describe Tuya::Cloud do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:endpoint) { "https://apigw.tuyaus.com" }
  let(:refresh) { "RT-1" }
  let(:now_ms) { (Time.now.to_f * 1000).to_i }
  let(:integration) do
    site.integrations.create!(driver: "tuya", name: "Smart Life", credentials: {
      "user_code" => "abc", "endpoint" => endpoint,
      "token" => { "t" => now_ms, "expire_time" => 7200, "uid" => "u1", "access_token" => "AT-1", "refresh_token" => refresh }
    }.to_json)
  end

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def relation(dp, code, type, desc = {})
    { "dpId" => dp, "statusCode" => code, "valueType" => type, "valueDesc" => desc.to_json, "supportLocal" => true }
  end

  # Responde `results[path]` cifrado com a chave do pedido; confere o X-sign.
  def fake_cloud(results, refresh_token: refresh)
    stub_request(:get, /#{Regexp.escape(endpoint)}/).to_return(lambda do |req|
      rid = req.headers["X-Requestid"]
      hash_key = Digest::MD5.hexdigest(rid + refresh_token)
      secret = described_class.secret(rid, hash_key)
      query = CGI.parse(URI(req.uri.to_s).query.to_s)["encdata"]&.first.to_s
      headers = { "X-appKey" => req.headers["X-Appkey"], "X-requestId" => rid, "X-sid" => "", "X-time" => req.headers["X-Time"],
                  "X-token" => req.headers["X-Token"] }
      raise "assinatura errada" unless req.headers["X-Sign"] == described_class.sign(hash_key, headers, query)

      path = URI(req.uri.to_s).path
      params = query.present? ? JSON.parse(described_class.decrypt(query, secret)) : {}
      result = results.fetch(path) { |p| results.fetch("#{p}?#{params.to_json}") }
      { body: { success: true, t: now_ms, result: described_class.encrypt(result.to_json, secret) }.to_json }
    end)
  end

  it "cifra e decifra como o SDK (AES-GCM com nonce em texto)" do
    secret = described_class.secret("rid", "hash")
    expect(secret.size).to eq(16)
    data = described_class.encrypt('{"a":1}', secret)
    expect(Base64.decode64(data[0, 16])).to match(/\A[A-Za-z0-9]{12}\z/)
    raw = Base64.decode64(data[0, 16]) + Base64.decode64(data[16..])
    expect(described_class.decrypt(Base64.strict_encode64(raw), secret)).to eq('{"a":1}')
  end

  it "login por QR: gera o token e espera o app confirmar" do
    stub_request(:post, "https://apigw.iotbing.com/v1.0/m/life/home-assistant/qrcode/tokens")
      .with(query: { clientid: "HA_3y9q4ak7g4ephrvke", usercode: "abc", schema: "haauthorize" })
      .to_return(body: { success: true, result: { qrcode: "QR1" } }.to_json)
    expect(described_class.qr_code("abc")).to eq("QR1")
    expect(described_class.qr_text("QR1")).to eq("tuyaSmart--qrLogin?token=QR1")

    stub_request(:get, %r{qrcode/tokens/QR1\?clientid=HA_3y9q4ak7g4ephrvke&usercode=abc})
      .to_return({ body: { success: false, code: 1 }.to_json },
                 { body: { success: true, t: 5, result: { endpoint: endpoint, terminal_id: "T", username: "eu@x", uid: "u",
                                                         access_token: "A", refresh_token: "R", expire_time: 7200 } }.to_json })
    expect(described_class.login_result("QR1", "abc")).to be_nil
    expect(described_class.login_result("QR1", "abc")).to include("endpoint" => endpoint, "username" => "eu@x",
                                                                   "token" => include("refresh_token" => "R", "t" => 5))

    stub_request(:post, /qrcode\/tokens\?clientid=.*usercode=errado/).to_return(body: { success: false, msg: "user code invalid" }.to_json)
    expect { described_class.qr_code("errado") }.to raise_error(described_class::Error, /user code/)
    stub_request(:post, /usercode=fora/).to_return(status: 500)
    expect { described_class.qr_code("fora") }.to raise_error(described_class::Error, /500/)
  end

  it "sem login não varre" do
    i = site.integrations.create!(driver: "tuya", name: "T", credentials: { "user_code" => "x" }.to_json)
    expect { described_class.new(i) }.to raise_error(Integrations::Error, /QR code/)
  end

  it "varre casas e aparelhos: chave local, cômodo, pontos pelo mapa de dps" do
    fake_cloud({
      "/v1.0/m/life/users/homes" => [ { "ownerId" => 77, "name" => "Casa" } ],
      %(/v1.0/m/life/ha/home/devices?{"homeId":"77"}) => [
        { "id" => "dev1", "name" => "Tomada Sala", "local_key" => "k1", "category" => "cz", "product_name" => "Smart Plug", "online" => true, "sub" => false },
        { "id" => "dev2", "name" => "Sensor porta", "local_key" => "k2", "category" => "mcs", "online" => false, "sub" => true },
        { "id" => "ir1", "name" => "TV", "category" => "infrared_tv", "online" => true, "sub" => false }
      ],
      # Controle IR virtual: a API devolve texto vazio no lugar do objeto (visto na conta real).
      "/v1.0/m/life/devices/ir1/status" => "", "/v1.1/m/life/ir1/specifications" => "", "/v1.0/m/thing/ha/ir1/room" => "",
      "/v1.0/m/life/devices/dev1/status" => { "productKey" => "p", "dpStatusRelationDTOS" => [
        relation(1, "switch_1", "Boolean"), relation(9, "countdown_1", "Integer"),
        relation(18, "cur_current", "Integer", unit: "mA", scale: 0), relation(19, "cur_power", "Integer", unit: "W", scale: 1),
        relation(20, "cur_voltage", "Integer", unit: "V", scale: 1), relation(38, "relay_status", "Enum", range: %w[on off])
      ] },
      "/v1.1/m/life/dev1/specifications" => { "functions" => [ { "code" => "switch_1" } ], "status" => [] },
      "/v1.0/m/thing/ha/dev1/room" => { "id" => 1, "name" => "Sala" },
      "/v1.0/m/life/devices/dev2/status" => { "dpStatusRelationDTOS" => [ relation(1, "doorcontact_state", "Boolean"), relation(2, "battery_percentage", "Integer", unit: "%", scale: 0) ] },
      "/v1.1/m/life/dev2/specifications" => { "functions" => [] },
      "/v1.0/m/thing/ha/dev2/room" => nil
    })
    list = described_class.new(integration).inventory
    expect(list.map { |e| e["id"] }).to eq(%w[dev1 dev2 ir1])
    expect(list.last).to include("room" => nil, "points" => [])
    plug = list.first
    expect(plug).to include("kind" => "tuya_local", "name" => "Tomada Sala", "secret" => "k1", "room" => "Sala", "category" => "Tomada", "online" => true,
                            "address" => { "version" => "3.3" })
    expect(plug["points"].map { |p| [ p["name"], p["capability"], p["address"]["dps"] ] })
      .to eq([ [ "Liga/desliga", "onoff", "1" ], [ "Corrente", "measure", "18" ], [ "Potência", "measure", "19" ], [ "Tensão", "measure", "20" ] ])
    expect(plug["points"][1]["scale"].to_d).to eq("0.001".to_d)
    sensor = list[1]
    expect(sensor).to include("sub" => true, "online" => false, "room" => nil)
    expect(sensor["points"].map { |p| p.values_at("name", "capability", "unit") }).to eq([ [ "Abertura", "contact", nil ], [ "Bateria", "measure", "%" ] ])
  end

  it "mapa de dps: lâmpada com brilho, vários interruptores, ajuste, seleção e risco pelo nome" do
    pts = described_class.points("Portão", [
      relation(20, "switch_led", "Boolean"), relation(22, "bright_value_v2", "Integer", min: 10, max: 1000, scale: 0),
      relation(1, "switch_1", "Boolean"), relation(2, "switch_2", "Boolean"),
      relation(24, "temp_set", "Integer", min: 50, max: 300, scale: 1, unit: "°C"), relation(21, "work_mode", "Enum", range: %w[white colour]),
      relation(30, "fault_alarm", "Boolean"), relation(31, "colour_data", "Json"), relation(32, "temp_current", "Integer", scale: 1)
    ], %w[switch_led bright_value_v2 switch_1 switch_2 temp_set work_mode])
    by = pts.index_by { |p| p["name"] }
    expect(by["Luz"]).to include("capability" => "onoff", "risk" => "critical")
    expect(by["Luz (brilho)"]).to include("capability" => "dimmer", "min" => 1, "max" => 100)
    expect(by.keys).to include("Interruptor 1", "Interruptor 2", "Temperatura desejada", "Modo", "Fault alarm", "Temperatura")
    expect(by["Temperatura desejada"]).to include("capability" => "setpoint", "min" => 5.0.to_d, "max" => 30.0.to_d)
    expect(by["Modo"]).to include("capability" => "enum", "options" => %w[white colour], "writable" => true)
    expect(by["Fault alarm"]["capability"]).to eq("problem")
    expect(by["Temperatura"]).to include("capability" => "measure", "unit" => "°C", "device_class" => "temperature")
  end

  it "renova o access token vencido e grava o novo" do
    integration.update!(credentials: integration.secrets.merge("token" => integration.secrets["token"].merge("t" => 0)).to_json)
    fake_cloud({ "/v1.0/m/token/#{refresh}" => { "accessToken" => "AT-2", "refreshToken" => "RT-2", "expireTime" => 7200, "uid" => "u1" } })
    stub_request(:get, /users\/homes/).to_return(lambda do |req|
      raise "token velho" unless req.headers["X-Token"] == "AT-2"

      rid = req.headers["X-Requestid"]
      secret = described_class.secret(rid, Digest::MD5.hexdigest("#{rid}RT-2"))
      { body: { success: true, result: described_class.encrypt("[]", secret) }.to_json }
    end)
    expect(described_class.new(integration).inventory).to eq([])
    expect(integration.reload.secrets["token"]).to include("access_token" => "AT-2", "refresh_token" => "RT-2")
  end

  it "erro da nuvem vira Error com a mensagem" do
    stub_request(:get, /users\/homes/).to_return(body: { success: false, msg: "token invalid" }.to_json)
    expect { described_class.new(integration).inventory }.to raise_error(described_class::Error, /token invalid/)
  end
end
