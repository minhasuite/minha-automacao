require "rails_helper"

# Movimento do DVR em tempo real (DvrEvents, 23/11/2026): o fluxo do eventManager do Intelbras/Dahua acende e
# apaga o ponto "Movimento" de cada câmera do DVR. Nada sai para a rede (WebMock).
RSpec.describe DvrEvents do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:frente) { create(:area, site: site, name: "Externo") }
  let(:dvr) do
    create(:device, site: site, driver: "go2rtc", name: "DVR Intelbras",
                    address: { "host" => "192.168.0.10", "username" => "admin", "events" => "dahua" }, credential: "s3nha")
  end
  let!(:cam1) { create(:point, device: dvr, area: frente, name: "Câmera Frente Esquerda", capability: "stream", address: { "path" => "/cam/realmonitor?channel=1&subtype=1" }) }
  let!(:cam2) { create(:point, device: dvr, area: frente, name: "Câmera Frente Direita", capability: "stream", address: { "path" => "/cam/realmonitor?channel=2&subtype=1" }) }
  let(:url) { %r{http://192\.168\.0\.10/cgi-bin/eventManager\.cgi\?action=attach} }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def motion(ch) = dvr.points.where(capability: "motion").find { |p| p.address["channel"] == ch }

  it "lê as linhas do Dahua: Start liga, Stop desliga, código fora da lista e batimento ignorados" do
    text = "--myboundary\r\nContent-Type: text/plain\r\n\r\nCode=VideoMotion;action=Start;index=0;data={\"SmartMotionEnable\" : true}\r\n" \
           "Code=SmartMotionHuman;action=Stop;index=1\r\nCode=HeartBeat;action=Pulse;index=0\r\nCode=VideoBlind;action=Start;index=2\r\n"
    expect(DvrEvents::Dahua.parse(text)).to eq([ [ "motion", 1, true ], [ "motion", 2, false ] ])
    expect(DvrEvents::Dahua.channel(cam2)).to eq(2)
  end

  it "um ponto de movimento por câmera, na área dela, sem duplicar" do
    pts = described_class.ensure_points!(dvr)
    expect(pts.map(&:name)).to contain_exactly("Movimento · Câmera Frente Esquerda", "Movimento · Câmera Frente Direita")
    expect(pts.map(&:area)).to all(eq(frente))
    expect { described_class.ensure_points!(dvr) }.not_to(change { Point.count })
    dvr.update!(address: dvr.address.except("events"))
    expect(described_class.ensure_points!(dvr)).to eq([])
  end

  it "o ouvinte acende e apaga o movimento pelo fluxo; caiu = indisponível" do
    body = "Code=VideoMotion;action=Start;index=0\r\nCode=VideoMotion;action=Start;index=1\r\nCode=VideoMotion;action=Stop;index=1\r\n"
    stub_request(:get, url).to_return(status: 200, body: body)
    expect(DvrEvents::Listener.run_once(dvr.id, limit: 3)).to be(true)
    expect(motion(1).reload.value).to be(true)
    expect(motion(2).reload.value).to be(false)
    expect(motion(1).quality).to eq("good")

    stub_request(:get, url).to_raise(Errno::EHOSTUNREACH)
    expect(DvrEvents::Listener.run_once(dvr.id)).to be(false)
    expect(motion(1).reload.quality).to eq("unavailable")
    expect(described_class.devices).to include(dvr)
  end

  it "Digest: responde ao desafio do DVR" do
    challenge = 'Digest realm="Login to DVR", qop="auth", nonce="abc", opaque="xyz"'
    stub_request(:get, url).with { |r| r.headers["Authorization"].nil? }.to_return(status: 401, headers: { "WWW-Authenticate" => challenge })
    ok = stub_request(:get, url).with { |r| r.headers["Authorization"].to_s.start_with?("Digest") }
                                .to_return(status: 200, body: "Code=VideoMotion;action=Start;index=0\r\n")
    expect(DvrEvents::Listener.run_once(dvr.id, limit: 1)).to be(true)
    expect(ok).to have_been_requested
    expect(motion(1).reload.value).to be(true)
  end
end
