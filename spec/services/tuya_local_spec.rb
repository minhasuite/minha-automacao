require "rails_helper"

RSpec.describe Drivers::TuyaLocal do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def tuya_device(fake, version: "3.5")
    create(:device, site: site, driver: "tuya_local", external_id: "abc123", credential: FakeTuyaDevice::KEY,
                    address: { "host" => "127.0.0.1", "port" => fake.port, "version" => version })
  end

  def wait_until(seconds = 3)
    deadline = Time.current + seconds
    sleep 0.05 until yield || Time.current > deadline
  end

  %w[3.3 3.4 3.5].each do |version|
    it "#{version}: liga a tomada pelo comando e lê a potência com escala" do
      fake = FakeTuyaDevice.new(version: version)
      device = tuya_device(fake, version: version)
      relay = create(:point, device: device, address: { "dps" => "1" })
      power = create(:point, device: device, name: "Potência", capability: "measure", address: { "dps" => "19" }, scale: "0.1")

      command = Points::Command.call(relay, "on", source: "web")
      expect(command.status).to eq("pending")
      perform_enqueued_jobs
      expect(command.reload.status).to eq("confirmed")
      expect(fake.state["1"]).to be true
      expect(relay.reload.value).to be true
      expect(power.reload.value).to eq(123.4)
      expect(device.reload.status).to eq("online")
    ensure
      fake&.stop
    end
  end

  it "brilho: valor da tela ↔ bruto do aparelho" do
    fake = FakeTuyaDevice.new(version: "3.3", state: { "20" => true, "22" => 1000 })
    p = create(:point, device: tuya_device(fake, version: "3.3"), capability: "dimmer", address: { "dps" => "22" }, scale: "0.1", min: 1)
    described_class.new.execute(p, "set", "50")
    expect(fake.state["22"]).to eq(500)
    expect(p.reload.value).to eq(50)
  ensure
    fake&.stop
  end

  it "aparelho fora do ar: comando falha com o motivo" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    device = create(:device, site: site, driver: "tuya_local", external_id: "x", credential: FakeTuyaDevice::KEY,
                             address: { "host" => "127.0.0.1", "port" => port, "version" => "3.3" })
    p = create(:point, device: device, address: { "dps" => "1" })
    command = Points::Command.call(p, "on", source: "web")
    perform_enqueued_jobs
    expect(command.reload).to have_attributes(status: "failed", error: /sem conexão/)

    p2 = create(:point, device: create(:device, site: site, driver: "tuya_local"), address: { "dps" => "1" })
    expect { described_class.new.execute(p2, "on", nil) }.to raise_error(described_class::Error, /host/)
    p3 = create(:point, device: device, name: "Sem dps")
    expect { described_class.new.execute(p3, "on", nil) }.to raise_error(described_class::Error, /dps/)
  end

  it "ouvinte: estado ao conectar, botão físico, comando pela conexão aberta e queda" do
    fake = FakeTuyaDevice.new(version: "3.5", state: { "1" => true })
    device = tuya_device(fake)
    device.update!(listen: true)
    relay = create(:point, device: device, address: { "dps" => "1" })

    thread = Thread.new { Tuya::Listener.run_once(device.id) }
    wait_until { relay.reload.value == true }
    expect(relay.value).to be true

    fake.push("1" => false) # botão físico
    wait_until { relay.reload.value == false }
    expect(relay.value).to be false

    wait_until { Tuya::Listener.connection(device.id) }
    described_class.new.execute(relay, "on", nil)
    wait_until { relay.reload.value == true }
    expect([ fake.state["1"], relay.value ]).to eq([ true, true ])

    fake.disconnect
    expect(thread.value).to be true
    expect(relay.reload.quality).to eq("unavailable")
    expect(device.reload.status).to eq("offline")
    expect(Tuya::Listener.connection(device.id)).to be_nil
  ensure
    thread&.kill
    fake&.stop
  end

  it "ouvinte: scan liga só os aparelhos com listen" do
    fake = FakeTuyaDevice.new
    device = tuya_device(fake)
    allow(Tuya::Listener).to receive(:listen)
    Tuya::Listener.scan
    expect(Tuya::Listener).not_to have_received(:listen)
    device.update!(listen: true)
    Tuya::Listener.scan
    sleep 0.1
    expect(Tuya::Listener).to have_received(:listen).with(device.id)
  ensure
    fake&.stop
  end
end

RSpec.describe Tuya::Import do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:data) do
    { "devices" => {
      "d1" => { "device_id" => "d1", "host" => "10.0.0.2", "local_key" => "k" * 16, "protocol_version" => "3.5",
                "friendly_name" => "Tomada 1",
                "entities" => [ { "id" => 1, "platform" => "switch", "friendly_name" => "SAL | Tomada", "current" => 18,
                                  "current_consumption" => 19, "voltage" => 20 } ] },
      "d2" => { "device_id" => "d2", "host" => "10.0.0.3", "local_key" => "j" * 16, "protocol_version" => "3.3",
                "friendly_name" => "Lâmpada",
                "entities" => [ { "id" => 20, "platform" => "light", "friendly_name" => "Lâmpada", "brightness" => 22,
                                  "brightness_lower" => 29, "brightness_upper" => 1000 },
                                { "id" => 5, "platform" => "sensor", "friendly_name" => "Outro" } ] },
      "d3" => { "device_id" => "d3", "host" => "10.0.0.4", "local_key" => "m" * 16, "protocol_version" => "3.4",
                "friendly_name" => "GAR Portão", "entities" => [ { "id" => 1, "platform" => "switch", "friendly_name" => "GAR | Portão" } ] }
    } }
  end

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  it "cria dispositivos e pontos numa área própria, sem ouvinte, e é idempotente" do
    r = described_class.call(site, data)
    expect([ r.devices, r.points ]).to eq([ 3, 7 ])
    expect(r.skipped).to eq([ "Lâmpada: sensor (dps 5)" ])

    tomada = Device.find_by!(external_id: "d1")
    expect(tomada).to have_attributes(driver: "tuya_local", listen: false, credential: "k" * 16, area: site.areas.find_by!(name: "Importados do HA"))
    expect(tomada.address).to eq({ "host" => "10.0.0.2", "version" => "3.5" })
    power = tomada.points.find_by!(name: "Potência")
    expect([ power.scale, power.unit, power.address ]).to eq([ BigDecimal("0.1"), "W", { "dps" => "19" } ])
    brilho = Device.find_by!(external_id: "d2").points.find_by!(capability: "dimmer")
    expect([ brilho.scale, brilho.min, brilho.max ]).to eq([ BigDecimal("0.1"), 3, 100 ])
    expect(Device.find_by!(external_id: "d3").points.first).to have_attributes(risk: "critical", confirm: "Acionar Portão?")

    data["devices"]["d1"]["host"] = "10.0.0.9"
    r = described_class.call(site, data)
    expect([ r.devices, r.points ]).to eq([ 3, 0 ])
    expect(tomada.reload.address["host"]).to eq("10.0.0.9")
  end

  it "rake tuya:importar lê o arquivo" do
    require "rake"
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    file = Rails.root.join("tmp/localtuya-spec.json")
    File.write(file, JSON.generate(data))
    site.update!(name: "Casa do spec")
    expect { Rake::Task["tuya:importar"].execute(Rake::TaskArguments.new(%i[arquivo local], [ file.to_s, "Casa do spec" ])) }
      .to output(/3 dispositivos, 7 pontos novos/).to_stdout
  ensure
    FileUtils.rm_f(file)
  end
end
