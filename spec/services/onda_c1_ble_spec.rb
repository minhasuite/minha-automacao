require "rails_helper"

# ondaC1 (C2): Bluetooth com o adaptador do servidor (HCI cru → Ble::Hub) e
# os formatos como plugins (BTHome cifrado, MiBeacon com bindkey, iBeacon,
# Oral-B). Vetores montados aqui; os cifrados são cifrados no próprio teste
# com o nonce de cada especificação. Nada de rádio.
RSpec.describe "Bluetooth completo (ondaC1, C2)" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:key_hex) { "231d39c1d7cc1ab1aee224cd096db932" }
  let(:key) { [ key_hex ].pack("H*") }
  let(:mac) { "54:48:E6:8F:80:A5" }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }
  before { allow(Rails).to receive(:cache).and_return(cache) }

  def ad(type, bytes) = [ bytes.size + 1, type, *bytes ].pack("C*")

  def ccm(nonce, pt, aad: nil)
    c = OpenSSL::Cipher.new("aes-128-ccm").encrypt
    c.iv_len = nonce.bytesize
    c.auth_tag_len = 4
    c.key = key
    c.iv = nonce
    c.ccm_data_len = pt.bytesize
    c.auth_data = aad if aad
    [ c.update(pt), c.auth_tag(4) ]
  end

  describe "formatos (Ble::PARSERS)" do
    it "BTHome cifrado: decifra com a chave do MAC e recusa sem chave ou com a errada" do
      plain = [ 0x02, 0xCA, 0x09, 0x03, 0xBF, 0x13 ].pack("C*")
      counter = [ 0x00112233 ].pack("V")
      nonce = Ble.mac_bytes(mac) + [ 0xFCD2 ].pack("v") + 0x41.chr + counter
      ct, tag = ccm(nonce, plain)
      data = ad(0x16, [ 0xD2, 0xFC, 0x41 ] + (ct + counter + tag).bytes)
      expect(Ble.decode(data, mac: mac, key: key_hex)).to eq([ "BTHome", { "temperature" => 25.06, "humidity" => 50.55 } ])
      expect(Ble.decode(data, mac: mac)).to be_nil
      expect(Ble.decode(data, mac: mac, key: "00" * 16)).to be_nil
    end

    it "Xiaomi MiBeacon: sem cifra (temperatura+umidade) e v5 cifrado com bindkey" do
      open = [ 0x50, 0x20, 0x5B, 0x05, 0x01 ].pack("C*") + Ble.mac_bytes(mac).reverse + [ 0x100D, 4 ].pack("vC") + [ 231, 455 ].pack("s<S<")
      expect(Ble.decode(ad(0x16, [ 0x95, 0xFE ] + open.bytes))[1]).to eq("temperature" => 23.1, "humidity" => 45.5)

      fc = 0x5848 # v5, cifrado, objeto, sem MAC no pacote
      pid, cnt, ext = [ 0x055B ].pack("v"), "\x07".b, "\x01\x02\x03".b
      obj = [ 0x100A, 1, 88 ].pack("vCC")
      ct, tag = ccm(Ble.mac_bytes(mac).reverse + pid + cnt + ext, obj, aad: "\x11".b)
      data = ad(0x16, [ 0x95, 0xFE ] + ([ fc ].pack("v") + pid + cnt + ct + ext + tag).bytes)
      expect(Ble.decode(data, mac: mac, key: key_hex)[1]).to eq("battery" => 88)
      expect(Ble.decode(data, mac: mac)).to be_nil
    end

    it "iBeacon: presença, distância pelo sinal e id próprio (uuid/major/minor)" do
      uuid = %w[e2 c5 6d b5 df fb 48 d2 b0 60 d0 f5 a7 10 96 e0].map(&:hex)
      data = ad(0xFF, [ 0x4C, 0x00, 0x02, 0x15 ] + uuid + [ 0x00, 0x01, 0x00, 0x02, 0xC5 ]) # tx -59 dBm a 1 m
      model, values, id = Ble.decode(data, rssi: -79)
      expect([ model, id ]).to eq([ "iBeacon 1/2", "ibeacon:e2c56db5-dffb-48d2-b060-d0f5a71096e0:1:2" ])
      expect(values).to eq("presence" => true, "rssi" => -79, "distance" => 10.0)
    end

    it "Oral-B: escovando, tempo, modo, pressão e setor" do
      data = ad(0xFF, [ 0xDC, 0x00, 0x02, 0x01, 0x07, 0x03, 0x32, 0x01, 0x0F, 0x01, 0x02 ])
      expect(Ble.decode(data)).to eq([ "Oral-B", { "brushing" => true, "brush_state" => "Escovando", "brush_time" => 75, "brush_mode" => "Limpeza diária",
                                                   "brush_pressure" => "Normal", "sector" => 2 } ])
      expect(Ble.points(Ble.decode(data)[1]).find { |p| p["address"]["field"] == "brush_mode" }).to include("capability" => "text", "writable" => false)
    end

    it "formato novo entra por registro (stub_const), sem mudar o núcleo" do
      fake = Class.new(Ble::Parsers::Base) do
        def self.parse(a, _ctx) = (d = a[:maker][0xFFFF]) && [ "Teste Balança", { "battery" => d.getbyte(0) } ]
      end
      stub_const("Ble::Parsers::TesteBalanca", fake)
      stub_const("Ble::PARSERS", Ble::PARSERS + %w[TesteBalanca])
      expect(Ble.decode(ad(0xFF, [ 0xFF, 0xFF, 42 ]))).to eq([ "Teste Balança", { "battery" => 42 } ])
    end
  end

  describe "HCI cru (bin/ble-scan)" do
    it "monta a varredura passiva e lê relatórios legados e estendidos (endereço invertido)" do
      expect(Ble::Hci.legacy_scan(true).last.bytes).to eq([ 0x01, 0x0C, 0x20, 0x02, 0x01, 0x00 ])
      data = ad(0x09, "Teste".bytes)
      addr = [ 0xA5, 0x80, 0x8F, 0xE6, 0x48, 0x54 ]
      legacy = [ 0x04, 0x3E, 0, 0x02, 1, 0x00, 0x00, *addr, data.bytesize ].pack("C*") + data + [ -70 ].pack("c")
      expect(Ble::Hci.reports(legacy)).to eq([ { "mac" => mac, "rssi" => -70, "data" => data } ])
      ext = [ 0x04, 0x3E, 0, 0x0D, 1, 0x10, 0x00, 0x00, *addr, 1, 0, 0xFF, 0x7F ].pack("C*") + [ -55 ].pack("c") +
            [ 0, 0, 0, 0, 0, 0, 0, 0, 0, data.bytesize ].pack("C*") + data
      expect(Ble::Hci.reports(ext)).to eq([ { "mac" => mac, "rssi" => -55, "data" => data } ])
      expect(Ble::Hci.command_status([ 0x04, 0x0E, 4, 1, 0x0C, 0x20, 0x00 ].pack("C*"), Ble::Hci::SET_SCAN_ENABLE)).to eq(0)
      expect(Ble::Hci.reports([ 0x04, 0x0E, 4, 1, 0x0C, 0x20, 0x00 ].pack("C*"))).to eq([])
    end
  end

  describe "adaptador do servidor (Ble::Hub)" do
    let(:integration) do
      i = site.integrations.create!(driver: "bluetooth", name: "Teste BT")
      i.merge_secrets!("bindkeys" => "#{mac}=#{key_hex}")
      i
    end
    let(:thermo) { ad(0x09, "Teste Termo".bytes) + ad(0x16, [ 0xD2, 0xFC, 0x40, 0x02, 0xCA, 0x09, 0x01, 0x5D ]) }

    it "anúncios viram inventário e o aparelho adotado recebe o valor na hora; presença vence sem anúncio" do
      n = Ble::Hub.ingest!(integration, [ { "mac" => "a4:c1:38:00:00:01", "rssi" => -60, "data" => Base64.strict_encode64(thermo) },
                                          { "mac" => "A4:C1:38:00:00:02", "rssi" => -60, "data" => Base64.strict_encode64(ad(0x09, "Fone".bytes)) },
                                          { "mac" => "lixo", "data" => "!!" } ], adapter: { "name" => "hci0" })
      expect(n).to eq(1)
      Integrations.sync!(integration)
      expect(integration.found.map { |e| e["name"] }).to eq([ "Teste Termo 00:01" ])
      Integrations.adopt!(integration, { "A4:C1:38:00:00:01" => "" })
      device = site.devices.find_by!(driver: "bluetooth")
      temp = device.points.find_by!(name: "Temperatura")
      expect(temp).to have_attributes(value: 25.06, writable: false)

      hotter = ad(0x16, [ 0xD2, 0xFC, 0x40, 0x02, 0x2E, 0x0B ])
      Ble::Hub.ingest!(integration, [ { "mac" => "A4:C1:38:00:00:01", "rssi" => -61, "data" => Base64.strict_encode64(hotter) } ])
      expect(temp.reload.value).to eq(28.62)
      expect(Drivers::Bluetooth.poll(device.reload)).not_to be_nil

      locals = Integrations::BluetoothPlugin.panel_locals(integration, {})
      expect(locals[:stats].first).to eq([ "Adaptador", "hci0" ])
      expect(locals[:rows].first.last).to include("Temperatura 28,62 °C")
    end

    it "iBeacon some: presença volta a falso depois de 3 min sem anúncio" do
      uuid = [ 0xAA ] * 16
      beacon = ad(0xFF, [ 0x4C, 0x00, 0x02, 0x15 ] + uuid + [ 0, 7, 0, 9, 0xC5 ])
      Ble::Hub.ingest!(integration, [ { "mac" => "11:22:33:44:55:66", "rssi" => -70, "data" => Base64.strict_encode64(beacon) } ])
      Integrations.sync!(integration)
      Integrations.adopt!(integration, integration.found.to_h { |e| [ e["id"], "" ] })
      device = site.devices.find_by!(driver: "bluetooth")
      expect(device.external_id).to start_with("ibeacon:")
      presence = device.points.find_by!(name: "Presença")
      Ble::Hub.ingest!(integration, [ { "mac" => "77:22:33:44:55:66", "rssi" => -70, "data" => Base64.strict_encode64(beacon) } ]) # MAC novo, mesmo beacon
      expect(presence.reload.value).to be true
      Ble::Hub.expire_presence!(integration, 4.minutes.from_now)
      expect(presence.reload.value).to be false
    end
  end
end
