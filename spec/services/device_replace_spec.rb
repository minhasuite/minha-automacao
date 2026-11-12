require "rails_helper"

# "Substituir aparelho" (Devices::Replace): o sensor Zigbee atrás do hub Tuya
# (tuya_cloud com address.via) vira o mesmo sensor pelo Zigbee2MQTT. O ponto
# antigo fica (id, chave, histórico, referências) com o endereço do novo.
RSpec.describe Devices::Replace do
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }
  let(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:cozinha) { within(tenant) { create(:area, site: site, name: "Cozinha") } }
  let(:old_device) { within(tenant) { create(:device, site: site, area: cozinha, name: "Porta da cozinha", driver: "tuya_cloud", external_id: "bf1", address: { "via" => "hub1" }) } }
  let!(:door) do
    within(tenant) do
      create(:point, device: old_device, name: "Abertura", key: "cozinha.porta", capability: "contact", device_class: "door", writable: false,
                     risk: "sensitive", address: { "code" => "doorcontact_state", "stale_open_s" => 600 }, value: true)
    end
  end
  let!(:battery) do
    within(tenant) { create(:point, device: old_device, name: "Bateria", capability: "measure", device_class: "battery", unit: "%", address: { "code" => "battery_percentage" }) }
  end
  let(:z2m) { file_fixture("z2m_bridge_devices.json").read }
  let(:new_device) { within(tenant) { site.devices.find_by!(driver: "mqtt", external_id: "0x00158d0004a1b2c3") } }

  around { |ex| within(tenant) { ex.run } }

  before { Mqtt::Z2m.discover!(site, z2m) }

  def by_old(pairs) = pairs.to_h { |p| [ p.old.id, p ] }

  it "sugere os pares por propriedade equivalente, capacidade e unidade (contato do z2m já no mesmo sentido)" do
    pairs = by_old(described_class.suggest(old_device, new_device))
    expect(pairs[door.id].new.address["json_path"]).to eq("contact")
    expect(pairs[door.id].invert).to be false # a descoberta do z2m guarda payload_on: false (contato aberto = verdadeiro)
    expect(pairs[battery.id].new.address["json_path"]).to eq("battery")
    expect(described_class.candidates(old_device)).to include(new_device)
    expect(described_class.candidates(old_device)).not_to include(old_device)
  end

  it "sugere inverter quando o ponto novo usa o sentido oposto (contact: true = fechado) e o invert vale na leitura e no comando" do
    raw = create(:device, site: site, name: "Contato cru", driver: "mqtt")
    contact = create(:point, device: raw, name: "Contato", capability: "contact", writable: false, address: { "topic" => "zigbee2mqtt/cru", "json_path" => "contact" })
    pair = by_old(described_class.suggest(old_device, raw))[door.id]
    expect(pair.new).to eq(contact)
    expect(pair.invert).to be true

    described_class.call(old_device, raw, [ pair ], user: owner)
    door.reload
    expect(door.address).to include("invert" => true, "json_path" => "contact", "stale_open_s" => 600)
    expect(Drivers::Mqtt.value_for(door, { contact: true }.to_json)).to be false # fechado
    expect(Drivers::Mqtt.value_for(door, { contact: false }.to_json)).to be true # aberto
    expect(described_class.true_is_active?(door)).to be true

    # Genérico: o mesmo campo no from_raw/to_raw (Tuya, Shelly…) e no payload do MQTT.
    lamp = create(:point, device: raw, name: "Relé", address: { "topic" => "x", "json_path" => "state", "invert" => true })
    expect(lamp.from_raw(true)).to be false
    expect(lamp.to_raw(true)).to be false
    expect(Drivers::Mqtt.payload(lamp, true)).to eq({ state: false }.to_json)
    expect(Points::Decode.invert({ "invert" => true }, 5)).to eq(5)
  end

  it "aplica: o ponto antigo fica (id, chave, área, risco, histórico e todas as referências) e o novo some" do
    Reading.record!(door, 2.hours.ago)
    other = create(:point, device: create(:device, site: site, name: "Luz"), name: "Luz da cozinha")
    link = PointLink.create!(source_point: door, target_point: other, mode: "trigger")
    notify = NotifyRule.create!(point: door, channels: %w[in_app])
    alert = AlertRule.create!(point: door, name: "Porta aberta", value: true)
    scene = Scene.create!(site: site, name: "Fim de tarde", items: [ { point_id: other.id, command: "on" } ])
    ref = ExternalRef.create!(site: site, source: "home_assistant", external_id: "binary_sensor.porta", kind: "entity", target: door)
    defn = { "schema_version" => 1, "views" => [ { "id" => "home", "title" => "Início", "sections" => [ { "id" => "s", "widgets" => [ { "id" => "w", "type" => "tile", "bind" => door.id } ] } ] } ] }
    dash = site.dashboards.create!(name: "Casa", kind: "custom", definition: defn)
    auto = Automation.create!(site: site, name: "Porta").tap { |a| a.publish!({ "triggers" => [ { "type" => "state", "point" => door.id } ], "actions" => [ { "type" => "notify", "channels" => [ "in_app" ], "title" => "x" } ] }) }
    window = create(:point, device: other.device, name: "Janela", capability: "contact", writable: false)
    group = HelperTypes.build(site, HelperTypes.plugin("group"))
    expect(HelperTypes.save(group, "name" => "Portas", "members" => [ door.id, window.id ])).to be true
    usages_before = Point.usages(site, Point.where(id: door.id)).map { |l, r| [ l, r.id ] }
    new_contact = new_device.points.find_by!("address->>'json_path' = 'contact'")
    new_ids = new_device.points.pluck(:id)

    pairs = described_class.pairs_from(old_device, new_device, "map" => { door.id => new_contact.id, battery.id => "" })
    event = described_class.call(old_device, new_device, pairs, user: owner, retire: "remove")

    door.reload
    expect(door).to have_attributes(device_id: new_device.id, key: "cozinha.porta", name: "Abertura", risk: "sensitive", area_id: cozinha.id, capability: "contact", device_class: "door")
    expect(door.address).to include("topic" => "zigbee2mqtt/porta_cozinha", "json_path" => "contact", "payload_on" => false, "stale_open_s" => 600)
    expect(door.address).not_to have_key("code")
    expect(Point.exists?(new_contact.id)).to be false
    expect(Reading.where(point_id: door.id).count).to eq(1)
    expect([ link.reload.source_point_id, notify.reload.point_id, alert.reload.point_id, ref.reload.target_id ]).to all(eq(door.id))
    expect(scene.reload.items).to be_present
    expect(dash.reload.definition.to_json).to include(door.id)
    expect(auto.reload.definition.to_json).to include(door.id)
    expect(group.reload.address["sources"]).to include(door.id)
    expect(Point.usages(site, Point.where(id: door.id)).map { |l, r| [ l, r.id ] }).to match_array(usages_before)
    expect(battery.reload.device_id).to eq(old_device.id) # sem par: fica no antigo
    expect(old_device.reload).to have_attributes(disabled: true, removed_at: nil) # sobrou ponto: desativado
    expect(event).to have_attributes(action: "device.replace", auditable_id: old_device.id, tenant_id: tenant.id)
    expect(event.details["pairs"].first).to include("old_point_id" => door.id, "new_point_id" => new_contact.id, "invert" => false)

    # O valor chega pelo tópico novo no ponto antigo; a descoberta de novo não duplica.
    expect(Drivers::Mqtt.value_for(door, { contact: false }.to_json)).to be true
    expect(Mqtt::Z2m.discover!(site, z2m)[:points]).to eq(0)

    # Desfazer: o ponto volta com o endereço de antes e o ponto novo volta com o mesmo id.
    described_class.undo!(event, user: owner)
    expect(door.reload).to have_attributes(device_id: old_device.id, address: { "code" => "doorcontact_state", "stale_open_s" => 600 })
    expect(new_device.points.pluck(:id)).to match_array(new_ids)
    expect(old_device.reload.disabled).to be false
    expect(event.reload.details["undone_at"]).to be_present
    expect(described_class.last_event(old_device)).to be_nil
    expect { described_class.undo!(event, user: owner) }.to raise_error(described_class::Error)
    expect(AuditEvent.where(action: "device.replace_undo", auditable_id: old_device.id)).to exist
  end

  it "todos os pontos mapeados: o aparelho antigo vira removido; 'deixar' não mexe" do
    pairs = described_class.suggest(old_device, new_device)
    expect(described_class.preview(old_device, new_device, pairs)).to include(retire: "remove", old_left: [])
    described_class.call(old_device, new_device, pairs, user: owner)
    expect(old_device.reload.removed_at).to be_present
    expect(old_device.points).to be_empty
    expect(battery.reload).to have_attributes(device_id: new_device.id, unit: "%")

    expect(described_class.retire_for(old_device, [], "keep")).to eq("keep")
    expect(described_class.retire_for(old_device, [], "xyz")).to eq("remove")
  end

  it "recusa par incompatível, ponto novo repetido, outro local e mapeamento vazio" do
    new_contact = new_device.points.find_by!("address->>'json_path' = 'contact'")
    new_batt = new_device.points.find_by!("address->>'json_path' = 'battery'")
    expect { described_class.pairs_from(old_device, new_device, "map" => { door.id => new_batt.id }) }.to raise_error(described_class::Error, /mesmo tipo/)
    expect { described_class.pairs_from(old_device, new_device, "pairs" => [ { "old" => door.id, "new" => new_contact.id }, { "old" => battery.id, "new" => new_contact.id } ]) }.to raise_error(described_class::Error)
    expect { described_class.pairs_from(old_device, new_device, "map" => { SecureRandom.uuid => new_contact.id }) }.to raise_error(described_class::Error)
    expect { described_class.call(old_device, new_device, [], user: owner) }.to raise_error(described_class::Error)
    elsewhere = create(:device, site: create(:site, name: "Loja"), name: "Outro")
    expect { described_class.call(old_device, elsewhere, described_class.suggest(old_device, new_device), user: owner) }.to raise_error(described_class::Error)
    expect(described_class.pairs_from(old_device, new_device, "pairs" => [ { "old" => door.id, "new" => new_contact.id, "invert" => "true" } ]).first.invert).to be true
  end
end
