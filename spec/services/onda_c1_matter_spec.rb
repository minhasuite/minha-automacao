require "rails_helper"

# ondaC1 (C3): Matter completo (multi-admin, comissionar pelo Bluetooth do
# servidor, Wi-Fi/Thread para comissionar, OTA) e Thread pelo OTBR (WebMock).
# Servidor Matter de mentira (FakeWs); nada de rede nem aparelho real.
RSpec.describe "Matter e Thread (ondaC1, C3)" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:node) do
    { "node_id" => 7, "available" => true,
      "attributes" => { "0/40/1" => "Acme", "0/40/3" => "Lâmpada", "0/40/5" => "Teste Luz", "0/40/10" => "1.0", "1/6/0" => true,
                        "0/62/1" => [ { "2" => 4937, "254" => 1 }, { "2" => 65_521, "254" => 2 } ] } }
  end
  let(:ws) do
    FakeWs.new({ "fabric_id" => 1, "compressed_fabric_id" => 99, "sdk_version" => "2025.1", "bluetooth_enabled" => true, "thread_credentials_set" => false }) do |msg|
      result = { "get_nodes" => [ node ], "start_listening" => [ node ], "commission_with_code" => { "node_id" => 8 },
                 "open_commissioning_window" => { "setup_pin_code" => 20_202_021, "setup_manual_code" => "34970112332", "setup_qr_code" => "MT:Y.K90AFN00KA0648G00" },
                 "check_node_update" => { "software_version" => 2, "software_version_string" => "2.0", "release_notes_url" => "https://exemplo.test/notas" } }[msg["command"]]
      { "message_id" => msg["message_id"], "result" => result }
    end
  end
  let(:matter) { site.integrations.create!(driver: "matter", name: "Teste Matter", settings: { "url" => "ws://10.0.0.5:5580/ws" }) }
  let(:otbr) { "http://10.0.0.6:8081" }
  # Dataset com canal 15, PAN 0x1234, rede "MA-Teste" e a chave da rede.
  let(:dataset) do
    tlv = ->(t, v) { [ t, v.bytesize ].pack("CC") + v }
    (tlv.call(0, [ 0, 15 ].pack("Cn")) + tlv.call(1, [ 0x1234 ].pack("n")) + tlv.call(2, "\x11" * 8) + tlv.call(3, "MA-Teste") + tlv.call(5, "\xAA" * 16)).unpack1("H*")
  end

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  before do
    allow(WsClient).to receive(:new).and_return(ws)
    allow(Rails).to receive(:cache).and_return(cache)
    allow(Integrations).to receive(:start_sync!)
  end

  def act(i, a, h = {}) = i.plugin.panel_action(i, a, ActionController::Parameters.new(h))

  it "multi-admin: abre a janela, guarda QR e código por 3 min e mostra com quem já está compartilhado" do
    act(matter, "share", node: "7")
    expect(ws.sent.find { |m| m["command"] == "open_commissioning_window" }["args"]).to eq("node_id" => 7, "timeout" => 180)
    l = matter.plugin.panel_locals(matter, {})
    expect(l[:share]).to include("name" => "Teste Luz", "manual" => "34970112332", "qr" => "MT:Y.K90AFN00KA0648G00")
    expect(Matter::Map.fabrics(node)).to eq(%w[apple test])
    expect(l[:info]).to include("bluetooth_enabled" => true)
  end

  it "comissiona pela rede ou pelo Bluetooth do servidor; Wi-Fi e remover" do
    act(matter, "commission", code: "3497-011-2332", mode: "ble")
    expect(ws.sent.last).to include("command" => "commission_with_code", "args" => { "code" => "34970112332", "network_only" => false })
    expect { act(matter, "commission", code: "abc") }.to raise_error(Integrations::Error)
    act(matter, "wifi", ssid: "Teste Rede", password: "segredo")
    expect(ws.sent.last).to include("command" => "set_wifi_credentials", "args" => { "ssid" => "Teste Rede", "credentials" => "segredo" })
    act(matter, "remove", node: "7")
    expect(ws.sent.last["command"]).to eq("remove_node")
    expect(Integrations).to have_received(:start_sync!).twice
  end

  it "firmware pelo ar (DCL) via Firmware::PROVIDERS" do
    device = site.devices.create!(driver: "matter", name: "Teste Luz", external_id: "7", integration: matter, address: { "node" => 7 })
    point = Firmware.check!(device)
    expect(Firmware.view(point.value)).to include(installed: "1.0", latest: "2.0", state: "available", notes_url: "https://exemplo.test/notas")
    Firmware.install!(point, user: nil)
    expect(ws.sent.last).to include("command" => "update_node", "args" => { "node_id" => 7, "software_version" => 2 })
  end

  describe "Thread (OTBR)" do
    before do
      stub_request(:get, "#{otbr}/node").to_return(status: 200, body: { "State" => "leader", "NumOfRouter" => 2 }.to_json)
      stub_request(:get, "#{otbr}/node/dataset/active").to_return(status: 200, body: dataset)
    end

    it "lê o nó e o dataset (chave mascarada), é a rede preferida e manda as credenciais ao Matter" do
      o = Integrations::ThreadPlugin.setup(site, ActionController::Parameters.new(url: otbr))
      expect(o.notice).to match(/leader/)
      thread = o.integration
      expect(thread.secrets["dataset"]).to eq(dataset)
      l = thread.plugin.panel_locals(thread, {})
      expect(l[:dataset]).to include("channel" => 15, "pan_id" => "0x1234", "network_name" => "MA-Teste", "network_key" => "••••")
      expect(l[:preferred]).to be true
      matter
      expect(act(thread, "send_matter").notice).to match(/1 servidor/)
      expect(ws.sent.last).to include("command" => "set_thread_dataset", "args" => { "dataset" => dataset })
      act(matter, "thread")
      expect(ws.sent.last["command"]).to eq("set_thread_dataset")
    end

    it "forma rede nova, importa dataset de outro app e recusa lixo" do
      put_ds = stub_request(:put, "#{otbr}/node/dataset/active").with(body: { "NetworkName" => "MA-Casa" }.to_json).to_return(status: 200)
      put_state = stub_request(:put, "#{otbr}/node/state").with(body: "enable").to_return(status: 200)
      thread = Integrations::ThreadPlugin.setup(site, ActionController::Parameters.new(url: otbr)).integration
      act(thread, "form", network_name: "MA-Casa")
      expect([ put_ds, put_state ]).to all(have_been_requested)
      expect { act(thread, "import", dataset: "zz") }.to raise_error(Integrations::Error, /inválido/)
      act(thread, "import", dataset: dataset.upcase)
      expect(thread.reload.secrets["dataset"]).to eq(dataset)
      second = Integrations::ThreadPlugin.setup(site, ActionController::Parameters.new(url: otbr)).integration
      expect(second.settings["preferred"]).to be_nil
      act(second, "prefer")
      expect([ thread.reload.settings["preferred"], second.reload.settings["preferred"] ]).to eq([ false, true ])
    end
  end
end
