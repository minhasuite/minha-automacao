require "rails_helper"

# ondaC1 (C5): ponte HomeKit (HAP nativo pelo serviço homekit-bridge/,
# testado com `npm test`). O Rails traduz ponto ↔ formato do hap-nodejs; o
# contrato entre os dois é o homekit-bridge/fixture.json.
RSpec.describe "Ponte HomeKit (ondaC1, C5)" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:device) { create(:device, site: site, name: "Sala", driver: "virtual") }
  let(:bridge) { Bridges::HomekitBridge }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def point(capability, **attrs) = create(:point, device: device, site: site, capability: capability, **attrs)
  def expose(p, **attrs) = BridgeExposure.create!(site: site, point: p, bridge: "homekit", **attrs)

  it "registrada nas pontes e na tela Expor; cada capacidade vira o serviço HAP certo" do
    expect(Bridges["homekit"]).to eq(bridge)
    expect(Exposure.targets(site).map(&:key)).to include("homekit", "matter", "google")
    lamp = create(:device, site: site, name: "Lâmpada", driver: "virtual")
    blind = create(:device, site: site, name: "Persiana", driver: "virtual")
    types = { point("gate", name: "Portão", risk: "critical") => "garage_door", point("dimmer", name: "Brilho") => "dimmable_light",
              point("color", name: "Cor") => "color_light", create(:point, device: lamp, site: site, capability: "onoff", name: "Liga") => "light",
              point("onoff", name: "Bomba") => "switch", create(:point, device: blind, site: site, capability: "setpoint", name: "Posição", unit: "%") => "window_covering",
              point("setpoint", name: "Alvo", unit: "°C", device_class: "temperature") => "thermostat", point("contact", name: "Porta") => "contact_sensor",
              point("motion", name: "Presença") => "motion_sensor", point("measure", name: "T", device_class: "temperature") => "temperature_sensor",
              point("measure", name: "U", device_class: "humidity") => "humidity_sensor" }
    types.each { |p, t| expect(bridge.type_for(p)).to eq(t), p.name }
    expect(bridge.type_for(point("text", name: "Recado"))).to be_nil
  end

  it "estado no formato do hap-nodejs bate com o fixture do serviço Node" do
    fixture = JSON.parse(Rails.root.join("homekit-bridge/fixture.json").read)["devices"].index_by { |d| d["type"] }
    expect(fixture.keys).to match_array(bridge::TYPES.keys)
    samples = { "garage_door" => point("gate", name: "Portão", value: "closed", risk: "critical"), "switch" => point("onoff", name: "Bomba", value: true),
                "color_light" => point("color", name: "Cor", value: { "h" => 120, "s" => 100, "v" => 80 }), "dimmable_light" => point("dimmer", name: "Brilho", value: 50),
                "thermostat" => point("setpoint", name: "Alvo", unit: "°C", value: 23), "contact_sensor" => point("contact", name: "Porta", value: false),
                "motion_sensor" => point("motion", name: "Presença", value: false), "temperature_sensor" => point("measure", name: "T", device_class: "temperature", value: 26.5),
                "humidity_sensor" => point("measure", name: "U", device_class: "humidity", value: 55) }
    samples.each do |type, p|
      state = bridge.state(type, p)
      expect(state.transform_values(&:keys)).to eq(fixture[type]["state"].transform_values(&:keys)), type
      expect(bridge.listen(type)).to eq(fixture[type]["listen"]), type
    end
    expect(bridge.state("garage_door", samples["garage_door"])).to eq(fixture["garage_door"]["state"])
    expect(bridge.state("contact_sensor", samples["contact_sensor"])).to eq("ContactSensor" => { "ContactSensorState" => 0 })
  end

  it "mudança vinda do app Casa vira comando (portão só pulsa quando muda) e a lista do serviço" do
    gate = point("gate", name: "Portão", risk: "critical", value: "closed")
    expect { expose(gate) }.to raise_error(ActiveRecord::RecordInvalid)
    expose(gate, risk_confirmed: "1")
    on = point("onoff", name: "Bomba", value: false)
    expose(on)
    expect(Bridges.command!(bridge, gate, "GarageDoorOpener.TargetDoorState", 1)).to be_nil
    expect(Bridges.command!(bridge, gate, "GarageDoorOpener.TargetDoorState", 0)).to have_attributes(command: "pulse", source: "bridge")
    Bridges.command!(bridge, on, "Switch.On", true)
    expect(on.reload.value).to be true
    list = Bridges.devices(bridge, Site.where(id: site.id))
    expect(list.map { |d| d["type"] }).to contain_exactly("garage_door", "switch")
    expect(bridge.format_code("031-45-154")).to eq("031-45-154")
    expect(Bridges::MatterBridge.format_code("34970112332")).to eq("3497-011-2332")
  end
end
