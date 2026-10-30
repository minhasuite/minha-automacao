require "rails_helper"

# Conta Xiaomi com servidores falsos: login (senha, captcha, 2FA, QR) e a API
# cifrada em RC4 do app, conferindo a assinatura como a Xiaomi faz.
RSpec.describe Miio::Cloud do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:ssecurity) { Base64.strict_encode64("s" * 16) }
  let(:integration) { site.integrations.create!(driver: "xiaomi", name: "Xiaomi", credentials: { "username" => "eu@x", "password" => "segredo", "region" => "us" }.to_json) }
  let(:token) { "0123456789abcdef0123456789abcdef" }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def account(body) = { body: "&&&START&&&#{body.to_json}" }

  def stub_sts
    stub_request(:get, "https://sts.api.io.mi.com/sts?d=1").to_return(headers: { "Set-Cookie" => "serviceToken=ST-1; path=/" })
  end

  def logged!
    integration.update!(credentials: integration.secrets.merge("user_id" => "42", "ssecurity" => ssecurity, "service_token" => "ST").to_json)
  end

  # API falsa: decifra o pedido, confere a assinatura e devolve `results[path]` cifrado.
  def fake_api(results, region: "us")
    stub_request(:post, %r{https://#{region}\.api\.io\.mi\.com/app/}).to_return(lambda do |req|
      q = URI.decode_www_form(URI(req.uri.to_s).query).to_h
      path = URI(req.uri.to_s).path.delete_prefix("/app")
      signed = Base64.strict_encode64(Digest::SHA256.digest(Base64.decode64(q["ssecurity"]) + Base64.decode64(q["_nonce"])))
      raise "assinatura" unless q["signature"] == described_class.signature(path, signed, q.slice("data", "rc4_hash__"))
      raise "cookie" unless req.headers["Cookie"].include?("serviceToken=ST")

      data = JSON.parse(described_class.rc4(Base64.decode64(signed), Base64.decode64(q["data"])))
      result = results.fetch(path).then { |r| r.respond_to?(:call) ? r.call(data) : r }
      { body: Base64.strict_encode64(described_class.rc4(Base64.decode64(signed), result.to_json)) }
    end)
  end

  it "RC4 com descarte de 1024 bytes ida e volta" do
    enc = described_class.rc4("chave", "texto")
    expect(enc).not_to eq("texto")
    expect(described_class.rc4("chave", enc)).to eq("texto")
  end

  it "login por senha: _sign, hash MD5 e sessão pelo STS" do
    stub_request(:get, "https://account.xiaomi.com/pass/serviceLogin?sid=xiaomiio&_json=true").to_return(account(_sign: "SIGN"))
    auth = stub_request(:post, /serviceLoginAuth2/).with(query: hash_including("user" => "eu@x", "_sign" => "SIGN", "hash" => Digest::MD5.hexdigest("segredo").upcase))
                                                    .to_return(account(ssecurity: ssecurity, userId: 42, location: "https://sts.api.io.mi.com/sts?d=1"))
    stub_sts
    expect(described_class.new(integration).login).to eq(:ok)
    expect(auth).to have_been_requested
    expect(integration.reload.secrets).to include("user_id" => "42", "ssecurity" => ssecurity, "service_token" => "ST-1")
    expect(described_class.new(integration)).to be_logged_in
  end

  it "captcha: guarda a imagem, manda o texto de volta; 2FA e senha errada" do
    stub_request(:get, /serviceLogin\?/).to_return(account(_sign: "S"))
    stub_request(:post, /serviceLoginAuth2/).to_return(account(captchaUrl: "/pass/getCode?icodeType=login"), account(notificationUrl: "https://x/verify"), account(code: 70016))
    stub_request(:get, "https://account.xiaomi.com/pass/getCode?icodeType=login").to_return(body: "IMG", headers: { "Set-Cookie" => "ick=I1; path=/" })
    expect(described_class.new(integration).login).to eq(:captcha)
    expect(integration.reload.secrets).to include("captcha" => Base64.strict_encode64("IMG"))
    expect(integration.secrets["cookies"]).to include("ick" => "I1")
    expect(described_class.new(integration).login(captcha: "abcd")).to eq(:two_factor)
    expect(WebMock).to have_requested(:post, /serviceLoginAuth2.*captCode=abcd/)
    expect { described_class.new(integration).login }.to raise_error(described_class::Error, /não conferem/)
  end

  it "login por QR: gera, espera e entra" do
    stub_request(:get, /longPolling\/loginUrl/).to_return(account(qr: "https://account.xiaomi.com/qr.png", lp: "https://lp.xiaomi.com/poll", loginUrl: "https://x"))
    stub_request(:get, "https://account.xiaomi.com/qr.png").to_return(body: "PNG")
    cloud = described_class.new(integration)
    expect(cloud.qr_start).to eq("PNG")
    stub_request(:get, "https://lp.xiaomi.com/poll").to_raise(Net::ReadTimeout).then
                                                     .to_return(status: 404).then
                                                     .to_return(account(ssecurity: ssecurity, userId: 7, location: "https://sts.api.io.mi.com/sts?d=1"))
    stub_sts
    expect(described_class.new(integration.reload).qr_poll).to be false
    expect(described_class.new(integration.reload).qr_poll).to be false
    expect(described_class.new(integration.reload).qr_poll).to be true
    expect(integration.reload.secrets).to include("user_id" => "7", "service_token" => "ST-1")
    expect(integration.secrets["lp"]).to be_nil

    stub_request(:get, /longPolling\/loginUrl/).to_return(account({}))
    expect { cloud.qr_start }.to raise_error(described_class::Error, /QR/)
  end

  it "lista casas, compartilhadas e aparelhos com token, IP e cômodo" do
    logged!
    stub_request(:get, %r{miot-spec.org/miot-spec-v2/instances}).to_return(body: { instances: [] }.to_json)
    fake_api({
      "/v2/homeroom/gethome" => { result: { homelist: [ { id: 1, name: "Casa", roomlist: [ { name: "Sala", dids: [ "100" ] } ] } ] } },
      "/v2/user/get_device_cnt" => { result: { share: { share_family: [ { home_id: 9, home_owner: 55 } ] } } },
      "/v2/home/home_device_list" => lambda { |data|
        if data["home_id"] == 1
          { result: { device_info: [ { did: "100", name: "Robô", model: "xiaomi.vacuum.d109gl", token: token, localip: "192.168.0.9", isOnline: true },
                                     { did: "blt.1", name: "BLE", model: "x.sensor", token: "", localip: "" } ] } }
        else
          raise "dono" unless data["home_owner"] == 55

          { result: { device_info: [ { did: "200", name: "Lâmpada", model: "yeelink.light.x", token: token, localip: "192.168.0.10" } ] } }
        end
      }
    })
    list = described_class.new(integration).inventory
    expect(list.map { |e| e["id"] }).to eq(%w[100 200])
    robot = list.first
    expect(robot).to include("kind" => "xiaomi_miot", "secret" => token, "room" => "Sala", "online" => true, "poll_s" => 60,
                             "address" => { "host" => "192.168.0.9", "model" => "xiaomi.vacuum.d109gl" }, "category" => "vacuum")
    expect(robot["points"].map { |p| p["capability"] }).to include("vacuum", "measure")
    expect(list.last["points"]).to eq([])
  end

  it "sessão vencida: limpa o token e pede login de novo" do
    logged!
    stub_request(:post, /api\.io\.mi\.com/).to_return(status: 401)
    expect { described_class.new(integration).inventory }.to raise_error(described_class::Error, /expirou/)
    expect(integration.reload.secrets["service_token"]).to be_nil
    expect { described_class.new(integration).inventory }.to raise_error(described_class::Error, /sem login/)
  end
end
