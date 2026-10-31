require "rails_helper"

# Pacote 1: Shelly Gen1 (HTTP, Basic) e Gen2 (RPC, Digest SHA-256), só WebMock.
RSpec.describe "Shelly" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:base) { "http://10.0.0.5" }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  before do
    stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[ShellyPlugin])
    stub_const("Drivers::REGISTRY", Drivers::REGISTRY.merge("shelly" => "Drivers::Shelly"))
    stub_const("Polling::DEVICES", Polling::DEVICES.merge("shelly" => "Drivers::Shelly"))
  end

  def json(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }

  def add(form)
    o = Integrations::ShellyPlugin.setup(site, ActionController::Parameters.new(form))
    expect(o.alert).to be_nil
    Integrations.adopt!(o.integration, o.integration.found.to_h { |e| [ e["id"], "" ] })
    site.devices.find_by!(driver: "shelly")
  end

  describe "Gen1" do
    let(:status) { { "relays" => [ { "ison" => true } ], "meters" => [ { "power" => 12.5, "total" => 6000 } ] } }

    before do
      stub_request(:get, "#{base}/shelly").to_return(json("type" => "SHSW-PM", "mac" => "AABBCC112233", "auth" => true))
      stub_request(:get, "#{base}/settings").with(basic_auth: %w[admin s3nha]).to_return(json("name" => "Bomba", "mode" => "relay", "device" => { "hostname" => "shelly1pm-112233" }))
      stub_request(:get, "#{base}/status").with(basic_auth: %w[admin s3nha]).to_return(json(status))
    end

    it "lê relé, potência e energia (watt-minuto → kWh), comanda e relê" do
      device = add(host: "10.0.0.5", password: "s3nha")
      expect(device).to have_attributes(name: "Bomba", external_id: "aabbcc112233", model: "SHSW-PM", poll_s: 30)
      expect(device.address).to include("host" => "10.0.0.5", "gen" => 1)
      pts = device.points.index_by(&:name)
      expect(pts.keys).to contain_exactly("Liga/desliga", "Potência", "Energia")
      expect(pts["Energia"]).to have_attributes(unit: "kWh", state_class: "total_increasing", writable: false)

      Drivers::Shelly.poll(device)
      expect(pts["Liga/desliga"].reload.value).to be true
      expect(pts["Potência"].reload.value).to eq(12.5)
      expect(pts["Energia"].reload.value.to_f).to be_within(0.001).of(0.1)

      off = stub_request(:get, "#{base}/relay/0?turn=off").with(basic_auth: %w[admin s3nha]).to_return(json("ison" => false))
      status["relays"][0]["ison"] = false
      stub_request(:get, "#{base}/status").with(basic_auth: %w[admin s3nha]).to_return(json(status))
      Drivers::Shelly.new.execute(pts["Liga/desliga"], "off", nil)
      expect(off).to have_been_requested
      expect(pts["Liga/desliga"].reload.value).to be false
    end

    it "fora do ar vira aviso no assistente e indisponível na leitura" do
      device = add(host: "10.0.0.5", password: "s3nha")
      stub_request(:get, "#{base}/status").to_raise(Errno::EHOSTUNREACH)
      expect { Drivers::Shelly.poll(device) }.to raise_error(Shelly::Error, /Sem conexão/)
      Drivers::Shelly.unavailable!(device)
      expect(device.points.reload.map(&:quality).uniq).to eq([ "unavailable" ])
    end
  end

  describe "Gen2" do
    let(:status) do
      { "sys" => { "uptime" => 10 }, "switch:0" => { "id" => 0, "output" => false, "apower" => 0, "voltage" => 229.5, "current" => 0, "aenergy" => { "total" => 1500.0 } },
        "switch:1" => { "id" => 1, "output" => true, "apower" => 60.2 } }
    end

    before do
      stub_request(:get, "#{base}/shelly").to_return(json("id" => "shellyplus2pm-a8032ab12345", "mac" => "A8032AB12345", "model" => "SNSW-102P16EU", "gen" => 2, "auth_en" => true))
      challenge = 'Digest qop="auth", realm="shellyplus2pm-a8032ab12345", nonce="60dc59c6", algorithm=SHA-256'
      stub_request(:post, "#{base}/rpc").to_return(status: 401, headers: { "WWW-Authenticate" => challenge })
      { "Shelly.GetDeviceInfo" => { "id" => "shellyplus2pm-a8032ab12345", "name" => "Quadro", "model" => "SNSW-102P16EU" }, "Shelly.GetStatus" => status }.each do |m, result|
        stub_request(:post, "#{base}/rpc").with(body: hash_including("method" => m), headers: { "Authorization" => /\ADigest .*algorithm=SHA-256/ })
                                          .to_return(json("id" => 1, "result" => result))
      end
    end

    it "lê por RPC com Digest SHA-256, numera os canais e comanda Switch.Set" do
      device = add(host: "10.0.0.5", password: "s3nha")
      expect(device).to have_attributes(name: "Quadro", external_id: "a8032ab12345")
      names = device.points.pluck(:name)
      expect(names).to contain_exactly("Liga/desliga 1", "Potência 1", "Tensão 1", "Corrente 1", "Energia 1", "Liga/desliga 2", "Potência 2")
      Drivers::Shelly.poll(device)
      expect(device.points.find_by!(name: "Energia 1").value.to_f).to eq(1.5)
      expect(device.points.find_by!(name: "Liga/desliga 2").value).to be true

      set = stub_request(:post, "#{base}/rpc").with(body: hash_including("method" => "Switch.Set", "params" => { "id" => 1, "on" => false }), headers: { "Authorization" => /Digest/ })
                                              .to_return(json("id" => 1, "result" => { "was_on" => true }))
      Drivers::Shelly.new.execute(device.points.find_by!(name: "Liga/desliga 2"), "off", nil)
      expect(set).to have_been_requested
    end

    it "persiana: posição e movimento pelo mapa, Cover.Open e GoToPosition" do
      attrs = Shelly.points(2, { "cover:0" => { "state" => "opening", "current_pos" => 30 } })
      expect(attrs.map { |a| a["name"] }).to eq(%w[Posição Movimento])
      device = create(:device, site: site, driver: "shelly", address: { "host" => "10.0.0.5", "port" => 80, "gen" => 2 })
      pos, move = attrs.map { |a| device.points.create!(a.merge("site" => site, "key" => "c.#{a['name'].parameterize(separator: '_')}")) }
      expect(Shelly.value_for(move, { "cover:0" => { "state" => "closing" } })).to eq("close")
      open = stub_request(:post, "#{base}/rpc").with(body: hash_including("method" => "Cover.Open", "params" => { "id" => 0 })).to_return(json("result" => nil))
      go = stub_request(:post, "#{base}/rpc").with(body: hash_including("method" => "Cover.GoToPosition", "params" => { "id" => 0, "pos" => 40 })).to_return(json("result" => nil))
      Shelly.command({ "host" => "10.0.0.5", "gen" => 2 }, move, "open")
      Shelly.command({ "host" => "10.0.0.5", "gen" => 2 }, pos, 40)
      expect([ open, go ]).to all(have_been_requested)
    end
  end

  it "erro do RPC vira mensagem" do
    stub_request(:post, "#{base}/rpc").to_return(json("id" => 1, "error" => { "code" => -103, "message" => "Invalid argument" }))
    expect { Shelly.rpc({ "host" => "10.0.0.5", "gen" => 2 }, "Switch.Set") }.to raise_error(Shelly::Error, /Invalid argument/)
  end

  it "plugin falso no mapa: componente novo entra só com dado" do
    stub_const("Shelly::MAP", Shelly::MAP.merge("gen2" => Shelly::MAP["gen2"].merge("lux" => [ { "field" => "lux", "name" => "Luz ambiente", "unit" => "lx" } ])))
    expect(Shelly.points(2, { "lux:0" => { "lux" => 120 } }).first).to include("name" => "Luz ambiente", "unit" => "lx")
  end
end
