require "rails_helper"

# ondaC1 (C1): Z-Wave JS completo. Servidor de mentira (FakeWs) no lugar do
# WebSocket; a inclusão S2 corre entre a tela e o ouvinte pelo cache
# (MemoryStore aqui). Nada de rádio nem aparelho real.
RSpec.describe "Z-Wave JS completo (ondaC1, C1)" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:nodes) do
    [ { "nodeId" => 1, "isControllerNode" => true, "status" => 4, "values" => [] },
      { "nodeId" => 5, "name" => "Teste Sensor", "status" => 4, "isSecure" => true, "highestSecurityClass" => 1, "firmwareVersion" => "1.2",
        "deviceConfig" => { "manufacturer" => "Aeotec", "label" => "ZW100" },
        "values" => [
          { "commandClass" => 113, "endpoint" => 0, "property" => "Home Security", "propertyKey" => "Motion sensor status", "value" => 0, "metadata" => { "label" => "Motion sensor status" } },
          { "commandClass" => 113, "endpoint" => 0, "property" => "Access Control", "propertyKey" => "Door state", "value" => 23, "metadata" => {} },
          { "commandClass" => 113, "endpoint" => 0, "property" => "Unknown Type", "propertyKey" => "x", "value" => 1, "metadata" => {} },
          { "commandClass" => 37, "endpoint" => 0, "property" => "currentValue", "value" => false, "metadata" => {} },
          { "commandClass" => 91, "endpoint" => 0, "property" => "scene", "propertyKey" => "001", "metadata" => { "label" => "Scene 001" } } ] },
      { "nodeId" => 6, "status" => 3, "values" => [] } ]
  end
  let(:ws) do
    FakeWs.new({ "type" => "version", "maxSchemaVersion" => 40, "driverVersion" => "15.0.0", "serverVersion" => "3.0.0" }) do |msg|
      result = case msg["command"]
      when "start_listening" then { "state" => { "controller" => { "homeId" => 3_405_691_582, "sdkVersion" => "7.21" }, "nodes" => nodes } }
      when "controller.get_node_neighbors" then { "neighbors" => { 1 => [ 5, 6 ], 5 => [ 1 ], 6 => [ 1 ] }[msg["nodeId"]] }
      when "controller.get_provisioning_entries" then { "entries" => [] }
      when "controller.get_available_firmware_updates" then { "updates" => [ { "version" => "1.10" }, { "version" => "1.9" } ] }
      else {}
      end
      { "type" => "result", "messageId" => msg["messageId"], "success" => true, "result" => result }
    end
  end
  let(:integration) do
    i = site.integrations.create!(driver: "zwave_js", name: "Teste Z-Wave", settings: { "url" => "ws://10.0.0.90:3000" })
    Integrations.sync!(i)
    Integrations.adopt!(i, i.found.to_h { |e| [ e["id"], "" ] })
    i
  end

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  before do
    allow(WsClient).to receive(:new).and_return(ws)
    allow(Rails).to receive(:cache).and_return(cache)
  end

  def pts(node) = site.devices.find_by!(external_id: "zwave:3405691582:#{node}").points.reload.index_by(&:name)
  def event(name, **h) = { "type" => "event", "event" => { "source" => h.delete(:source) || "node", "event" => name }.merge(h.stringify_keys) }

  it "notificação (113) vira movimento/abertura pelo mapa; cena central vira evento; tipo desconhecido fica de fora" do
    integration
    p = pts(5)
    expect(p.keys).to contain_exactly("Movimento", "Abertura", "Liga/desliga", "Scene 001")
    expect(p["Movimento"]).to have_attributes(capability: "motion", value: false, writable: false)
    expect(p["Abertura"]).to have_attributes(capability: "contact", value: false)
    expect(p["Scene 001"]).to have_attributes(capability: "event", writable: false)
  end

  it "ouvinte: valores em tempo real, nó morto e o vivo de novo" do
    integration
    ws.push(event("value updated", nodeId: 5, args: { "commandClass" => 113, "endpoint" => 0, "property" => "Home Security", "propertyKey" => "Motion sensor status", "newValue" => 8 }))
    ws.push(event("value updated", nodeId: 5, args: { "commandClass" => 113, "endpoint" => 0, "property" => "Access Control", "propertyKey" => "Door state", "newValue" => 22 }))
    ws.push(event("value notification", nodeId: 5, args: { "commandClass" => 91, "endpoint" => 0, "property" => "scene", "propertyKey" => "001", "value" => 0 }))
    ws.push(event("dead", nodeId: 5))
    ws.finish!
    expect(ZwaveJs::Listener.session(integration.id, client: ZwaveJs::Client.new("ws://x", ws: ws.connect).connect)).to be true
    p = pts(5)
    expect([ p["Movimento"].value, p["Abertura"].value, p["Scene 001"].value ]).to eq([ true, true, 0 ])
    expect(site.devices.find_by!(external_id: "zwave:3405691582:5").status).to eq("offline")
  end

  it "inclusão S2: tela pede → ouvinte inclui → concede as classes → PIN do DSK → nó entrevistado varre de novo" do
    integration
    plugin = Integrations::ZwaveJsPlugin
    act = ->(a, h = {}) { plugin.panel_action(integration, a, ActionController::Parameters.new(h)) }
    client = ZwaveJs::Client.new("ws://x", ws: ws.connect).connect
    listener = ZwaveJs::Listener

    expect(act.call("include", strategy: "s2").notice).to match(/60 s/)
    expect(plugin.panel_refresh(integration)).to eq(2000)
    listener.pump(integration.id, client)
    expect(ws.sent.last).to include("command" => "controller.begin_inclusion", "options" => { "strategy" => 4 })

    listener.handle(integration.id, event("grant security classes", source: "controller", requested: { "securityClasses" => [ 1, 0 ], "clientSideAuth" => false })["event"])
    expect(ZwaveJs::Inclusion.get(integration.id)).to include("state" => "grant", "requested" => [ 1, 0 ])
    act.call("grant", classes: %w[1 7]) # 7 não foi pedida: fica de fora
    listener.pump(integration.id, client)
    expect(ws.sent.last).to include("command" => "controller.grant_security_classes", "inclusionGrant" => { "securityClasses" => [ 1 ], "clientSideAuth" => false })

    listener.handle(integration.id, event("validate dsk and enter pin", source: "controller", dsk: "-23456-34567-45678-56789-67890-78901-89012")["event"])
    expect { act.call("pin", pin: "12") }.to raise_error(Integrations::Error, /5 dígitos/)
    act.call("pin", pin: "12345")
    listener.pump(integration.id, client)
    expect(ws.sent.last).to include("command" => "controller.validate_dsk_and_enter_pin", "pin" => "12345")

    listener.handle(integration.id, event("node added", source: "controller", node: { "nodeId" => 9 }, result: { "lowSecurity" => false })["event"])
    expect(ZwaveJs::Inclusion.get(integration.id)["state"]).to eq("added")
    expect(Integrations).to receive(:start_sync!).with(integration)
    listener.handle(integration.id, event("interview completed", nodeId: 9)["event"])
    expect(ZwaveJs::Inclusion.get(integration.id)["state"]).to eq("done")
    expect(plugin.panel_refresh(integration)).to be_nil
  end

  it "exclusão, parar, SmartStart pelo QR, refazer rotas, remover nó com falha e reentrevistar" do
    integration
    plugin = Integrations::ZwaveJsPlugin
    act = ->(a, h = {}) { plugin.panel_action(integration, a, ActionController::Parameters.new(h)) }
    client = ZwaveJs::Client.new("ws://x", ws: ws.connect).connect
    act.call("exclude")
    ZwaveJs::Listener.pump(integration.id, client)
    act.call("stop")
    ZwaveJs::Listener.pump(integration.id, client)
    expect(ws.commands.last(2)).to eq(%w[controller.begin_exclusion controller.stop_exclusion])
    expect(ZwaveJs::Inclusion.get(integration.id)["state"]).to eq("stopped")

    expect { act.call("smart_start", qr: "123") }.to raise_error(Integrations::Error, /SmartStart/)
    qr = "90#{'1' * 88}"
    act.call("smart_start", qr: qr)
    expect(ws.sent.last).to include("command" => "controller.provision_smart_start_node", "entry" => qr)
    act.call("rebuild_routes")
    act.call("reinterview", node: "5")
    allow(Integrations).to receive(:start_sync!)
    act.call("remove_failed", node: "6")
    expect(ws.sent.reject { |m| m["command"] == "set_api_schema" }.last(3).map { |m| [ m["command"], m["nodeId"] ] }).to eq([ [ "controller.begin_rebuilding_routes", nil ], [ "node.refresh_info", 5 ], [ "controller.remove_failed_node", 6 ] ])
  end

  it "tela: resumo, mapa pelos vizinhos e lista de nós" do
    integration
    l = Integrations::ZwaveJsPlugin.panel_locals(integration, {})
    expect(l[:controller]["homeId"]).to eq(3_405_691_582)
    expect(l[:map][:nodes].find { |n| n[:controller] }).to include(x: 50.0, y: 50.0)
    expect(l[:map][:edges]).to contain_exactly([ 1, 5 ], [ 1, 6 ])
    expect(l[:map][:nodes].find { |n| n[:id] == 6 }[:status]).to eq("dead")
  end

  it "firmware pelo ar (registro Firmware::PROVIDERS)" do
    integration
    device = site.devices.find_by!(external_id: "zwave:3405691582:5")
    expect(Firmware.provider(device)).to eq(Firmware::Providers::ZwaveJs)
    point = Firmware.check!(device)
    expect(Firmware.view(point.value)).to include(installed: "1.2", latest: "1.10", state: "available")
    Firmware.install!(point, user: nil)
    expect(ws.sent.last).to include("command" => "controller.firmware_update_ota", "nodeId" => 5, "updateInfo" => { "version" => "1.10" })
  end
end
