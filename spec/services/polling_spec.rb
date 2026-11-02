require "rails_helper"

RSpec.describe Polling do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }
  before { allow(described_class).to receive(:sleep) }

  def tuya(fake, **attrs)
    create(:device, site: site, driver: "tuya_local", external_id: "abc", credential: FakeTuyaDevice::KEY,
                    address: { "host" => "127.0.0.1", "port" => fake.port, "version" => "3.3" }, **attrs)
  end

  it "lê os vencidos um por vez (com intervalo), só leitura, e não repete antes da hora" do
    fake = FakeTuyaDevice.new(version: "3.3")
    a = tuya(fake)
    relay = create(:point, device: a, address: { "dps" => "1" })
    b = tuya(fake, polled_at: 1.minute.ago)
    expect(a.poll_s).to eq(1800)
    fake.state["1"] = true
    described_class.run_due
    expect(relay.reload.value).to be true
    expect(a.reload.polled_at).to be_within(5.seconds).of(Time.current)
    expect(b.reload.polled_at).to be < 30.seconds.ago
    expect(Command.count).to eq(0)

    b.update!(polled_at: 2.hours.ago)
    described_class.run_due
    expect(b.reload.polled_at).to be_within(5.seconds).of(Time.current)
  ensure
    fake&.stop
  end

  it "intervalo entre aparelhos quando há mais de um vencido" do
    allow(described_class).to receive(:poll_device)
    2.times { create(:device, site: site, driver: "xiaomi_miot") }
    described_class.run_due
    expect(described_class).to have_received(:sleep).with(Polling::GAP).once
    expect(described_class).to have_received(:poll_device).twice
  end

  it "não lê desligado (nulo ou 0), desativado, com ouvinte, nem driver sem leitura" do
    allow(described_class).to receive(:poll_device)
    create(:device, site: site, driver: "tuya_local", poll_s: 0)
    create(:device, site: site, driver: "tuya_local", poll_s: nil)
    create(:device, site: site, driver: "tuya_local", disabled: true)
    create(:device, site: site, driver: "tuya_local", listen: true)
    create(:device, site: site, driver: "mqtt")
    described_class.run_due
    expect(described_class).not_to have_received(:poll_device)
    expect(described_class.supported?(build(:device, driver: "mqtt"))).to be false
  end

  it "falha marca indisponível e conta a tentativa" do
    device = create(:device, site: site, driver: "tuya_local", address: { "host" => "127.0.0.1", "port" => 1 }, external_id: "x", credential: "k" * 16)
    point = create(:point, device: device, address: { "dps" => "1" })
    expect(described_class.poll_device(device.id)).to be false
    expect(point.reload.quality).to eq("unavailable")
    expect(device.reload).to have_attributes(status: "offline", polled_at: be_present)
  end

  it "integração da Alexa vencida relê a lista de Echo" do
    integration = site.integrations.create!(driver: "alexa", name: "Alexa", credentials: { "csrf" => "C" }.to_json)
    stub_request(:get, "https://alexa.amazon.com.br/api/devices-v2/device?cached=true")
      .to_return({ body: { devices: [ { accountName: "Echo Sala", deviceFamily: "ECHO", serialNumber: "S", online: true } ] }.to_json }, { status: 500 })
    stub_request(:get, %r{\Ahttps://alexa\.amazon\.com\.br/api/(devices/deviceType|dnd|np)/}).to_return(body: "{}") # G12: estado da Echo
    described_class.run_due
    expect(integration.reload).to have_attributes(status: "ok", polled_at: be_present)
    expect(site.devices.find_by!(driver: "alexa").name).to eq("Echo Sala")
    integration.update!(polled_at: 2.hours.ago)
    expect(described_class.poll_integration(integration.id)).to be false
    expect(integration.reload.status).to eq("error")
  end

  it "minutos no formulário" do
    device = build(:device, poll_min: "1,5")
    expect(device.poll_s).to eq(90)
    expect(device.poll_min).to eq("1.5")
    device.poll_min = ""
    expect(device.poll_s).to be_nil
    expect(build(:device, poll_s: -1)).not_to be_valid
  end
end
