require "rails_helper"

# Pacote 1: Matter pelo python-matter-server, só com um servidor falso (dublê
# do WsClient que responde como o servidor). Registro por stub_const: o
# núcleo não muda.
RSpec.describe "Pacote 1: Matter" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  before do
    stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[MatterPlugin])
    stub_const("Drivers::REGISTRY", Drivers::REGISTRY.merge("matter" => "Drivers::Matter"))
    stub_const("Polling::DEVICES", Polling::DEVICES.merge("matter" => "Drivers::Matter"))
  end

  def connect_with(ws)
    allow(WsClient).to receive(:new).and_return(ws)
  end

  def integration
    ws = FakeMatterServer.new
    connect_with(ws)
    o = Integrations::MatterPlugin.setup(site, ActionController::Parameters.new(url: "ws://192.168.0.10:5580/ws"))
    [ o, ws ]
  end

  it "lista os nós como aparelhos com os pontos do mapa e adota sem duplicar" do
    o, = integration
    i = o.integration
    expect(o.to).to eq(:found)
    expect(i.settings).to include("url" => "ws://192.168.0.10:5580/ws", "account" => "192.168.0.10")
    e = i.found.first
    expect(e).to include("id" => "7", "kind" => "matter", "name" => "Luz do escritório", "manufacturer" => "Acme", "model" => "Lâmpada A19")
    expect(e["points"].map { |p| [ p["name"], p["capability"] ] }).to eq(
      [ [ "Liga/desliga", "onoff" ], [ "Intensidade", "dimmer" ], [ "Temperatura", "measure" ], [ "Movimento", "motion" ],
        [ "Abertura", "contact" ], [ "Iluminância", "measure" ], [ "Bateria", "measure" ], [ "Posição", "setpoint" ] ]
    )

    connect_with(FakeMatterServer.new)
    expect(Integrations.adopt!(i, { "7" => "" })).to eq(1)
    d = site.devices.find_by!(driver: "matter", external_id: "7")
    v = d.points.to_h { |p| [ p.name, p.value ] }
    expect(v).to include("Liga/desliga" => true, "Intensidade" => 50, "Temperatura" => 21.5, "Movimento" => true,
                         "Abertura" => false, "Iluminância" => 100.0, "Bateria" => 90.0, "Posição" => 75.0)
    expect(d.driver_label).to eq("Matter")
  end

  it "comanda pelo mapa: liga/desliga e nível viram device_command" do
    o, = integration
    connect_with(FakeMatterServer.new)
    Integrations.adopt!(o.integration, { "7" => "" })
    d = site.devices.find_by!(external_id: "7")
    onoff = d.points.find_by!(capability: "onoff")
    dimmer = d.points.find_by!(capability: "dimmer")
    cover = d.points.find_by!(capability: "setpoint")

    ws = FakeMatterServer.new
    connect_with(ws)
    Drivers::Matter.new.execute(onoff, "off", nil)
    Drivers::Matter.new.execute(dimmer, "set", 100)
    Drivers::Matter.new.execute(cover, "set", 100)
    args = ws.sent.select { |m| m["command"] == "device_command" }.map { |m| m["args"] }
    expect(args).to eq([
      { "node_id" => 7, "endpoint_id" => 1, "cluster_id" => 6, "command_name" => "Off", "payload" => {} },
      { "node_id" => 7, "endpoint_id" => 1, "cluster_id" => 8, "command_name" => "MoveToLevelWithOnOff", "payload" => { "transitionTime" => 0, "level" => 254 } },
      { "node_id" => 7, "endpoint_id" => 6, "cluster_id" => 258, "command_name" => "GoToLiftPercentage", "payload" => { "liftPercent100thsValue" => 0 } }
    ])
    expect(onoff.reload.value).to be(false)

    connect_with(FakeMatterServer.new(fail: "node offline"))
    expect { Drivers::Matter.new.execute(onoff, "on", nil) }.to raise_error(Drivers::Matter::Error, /node offline/)
  end

  it "ouvinte: attribute_updated vira report!, nó removido fica indisponível" do
    o, = integration
    connect_with(FakeMatterServer.new)
    Integrations.adopt!(o.integration, { "7" => "" })
    d = site.devices.find_by!(external_id: "7")
    ws = FakeMatterServer.new(events: [ { "event" => "attribute_updated", "data" => [ 7, "2/1026/0", 2300 ] } ])
    client = Matter::Client.new("ws://x", ws: ws.connect).connect
    expect(Matter::Listener.session(o.integration.id, client: client)).to be(true)
    expect(d.points.find_by!(name: "Temperatura").value).to eq(23.0)
    expect(d.points.find_by!(capability: "onoff").value).to be(false) # evento que veio no meio da resposta

    Matter::Listener.handle(o.integration.id, { "event" => "node_removed", "data" => 7 })
    expect(d.points.reload.map(&:quality).uniq).to eq([ "unavailable" ])
    expect(d.reload.status).to eq("offline")
  end

  it "comissiona pelo código e varre de novo; código inválido avisa" do
    o, = integration
    ws = FakeMatterServer.new
    connect_with(ws)
    r = Integrations::MatterPlugin.login(o.integration, ActionController::Parameters.new(code: "3497-011-2332"))
    expect(r.notice).to match(/comissionado \(nó 8\)/)
    expect(ws.sent.find { |m| m["command"] == "commission_with_code" }["args"]).to eq("code" => "34970112332", "network_only" => true)

    r = Integrations::MatterPlugin.login(o.integration, ActionController::Parameters.new(code: "123"))
    expect(r.alert).to match(/Código de pareamento inválido/)
  end

  it "servidor fora vira aviso, não exceção; URL inválida pede ws://" do
    allow(WsClient).to receive(:new).and_return(double.tap { |dbl| allow(dbl).to receive(:connect).and_raise(WsClient::Error, "recusado") })
    o = Integrations::MatterPlugin.setup(site, ActionController::Parameters.new(url: "ws://10.0.0.1:5580/ws"))
    expect(o.alert).to match(/recusado/)
    expect(Integrations::MatterPlugin.setup(site, ActionController::Parameters.new(url: "http://x")).alert).to match(/ws:/)
  end

  it "leitura periódica refaz o estado pelo get_nodes" do
    o, = integration
    connect_with(FakeMatterServer.new)
    Integrations.adopt!(o.integration, { "7" => "" })
    d = site.devices.find_by!(external_id: "7")
    node = FakeMatterServer::NODE.deep_merge("attributes" => { "2/1026/0" => 1800 })
    connect_with(FakeMatterServer.new(nodes: [ node ]))
    expect(Polling.poll_device(d.id)).to be(true)
    expect(d.points.find_by!(name: "Temperatura").value).to eq(18.0)
  end
end
