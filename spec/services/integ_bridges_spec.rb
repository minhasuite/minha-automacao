require "rails_helper"

# integ: pontes de exposição (Matter). O Rails traduz ponto ↔ formato do
# matter.js; o serviço Node (matter-bridge/, testado com `npm test`) só
# publica. O contrato entre os dois é o matter-bridge/fixture.json.
RSpec.describe "Pontes de exposição (integ)" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:device) { create(:device, site: site, name: "Lâmpada da sala") }
  let(:bridge) { Bridges::MatterBridge }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def point(capability, **attrs) = create(:point, device: device, site: site, capability: capability, **attrs)
  def expose(p, **attrs) = BridgeExposure.create!(site: site, point: p, bridge: "matter", **attrs)

  it "cada capacidade vira o tipo Matter certo (fechadura antes do liga/desliga, cortina e termostato pelo ponto)" do
    blind = create(:device, site: site, name: "Persiana do quarto")
    types = {
      point("onoff", name: "Luz") => "on_off_light", point("onoff", name: "Bomba") => "on_off_light", # o aparelho se chama "Lâmpada"
      point("dimmer", name: "Brilho") => "dimmable_light", point("color", name: "Cor") => "extended_color_light",
      point("gate", name: "Portão", risk: "critical") => "door_lock",
      create(:point, device: blind, site: site, capability: "setpoint", name: "Posição", unit: "%") => "window_covering",
      point("setpoint", name: "Alvo", unit: "°C", device_class: "temperature") => "thermostat",
      point("contact", name: "Porta") => "contact_sensor", point("motion", name: "Presença") => "occupancy_sensor",
      point("measure", name: "Temperatura", device_class: "temperature", unit: "°C") => "temperature_sensor",
      point("measure", name: "Umidade", device_class: "humidity", unit: "%") => "humidity_sensor"
    }
    types.each { |p, type| expect(bridge.type_for(p)).to eq(type), p.name }
    plug = create(:point, device: create(:device, site: site, name: "Tomada"), site: site, capability: "onoff", name: "Liga/desliga")
    expect(bridge.type_for(plug)).to eq("on_off_plug")
    expect(bridge.type_for(point("text", name: "Recado"))).to be_nil
    expect(Bridges.candidates(bridge, site).map(&:first)).to include(plug)
  end

  it "estado no formato do matter.js bate com o fixture do serviço Node (mesmos clusters e atributos)" do
    fixture = JSON.parse(Rails.root.join("matter-bridge/fixture.json").read)["devices"].index_by { |d| d["type"] }
    expect(fixture.keys).to match_array(bridge::TYPES.keys)
    samples = {
      "on_off_light" => point("onoff", name: "Luz", value: true), "dimmable_light" => point("dimmer", name: "Brilho", value: 50),
      "extended_color_light" => point("color", name: "Cor", value: { "mode" => "hs", "h" => 120, "s" => 100 }),
      "door_lock" => point("gate", name: "Portão", value: "closed", risk: "critical"),
      "thermostat" => point("setpoint", name: "Alvo", unit: "°C", value: 23),
      "contact_sensor" => point("contact", name: "Porta", value: false), "occupancy_sensor" => point("motion", name: "Presença", value: false),
      "temperature_sensor" => point("measure", name: "T", device_class: "temperature", value: 26.5),
      "humidity_sensor" => point("measure", name: "U", device_class: "humidity", value: 55)
    }
    samples.each do |type, p|
      state = bridge.state(type, p)
      expect(state.transform_values(&:keys)).to eq(fixture[type]["state"].transform_values(&:keys)), type
      expect(bridge.listen(type)).to eq(fixture[type]["listen"]), type
    end
    expect(bridge.state("extended_color_light", samples["extended_color_light"])["colorControl"]).to eq("currentHue" => 85, "currentSaturation" => 254)
    expect(bridge.state("contact_sensor", samples["contact_sensor"])).to eq("booleanState" => { "stateValue" => true }) # fechado = encostado
  end

  it "exposição: ponto crítico pede confirmação; a lista do serviço leva nome, estado e o que ouvir" do
    gate = point("gate", name: "Portão", risk: "critical", value: "closed")
    expect { expose(gate) }.to raise_error(ActiveRecord::RecordInvalid, /confirmação/)
    expose(gate, risk_confirmed: "1", name: "Portão da rua")
    light = point("onoff", name: "Luz", value: false)
    expose(light)
    point("onoff", name: "Abajur") # não exposto

    devices = Bridges.devices(bridge, Site.where(id: site.id))
    expect(devices.map { |d| d["name"] }).to contain_exactly("Portão da rua", "Luz")
    lock = devices.find { |d| d["type"] == "door_lock" }
    expect(lock).to include("state" => { "doorLock" => { "lockState" => 1 } }, "listen" => [ "doorLock.lockState" ], "reachable" => true)
  end

  describe "mudança vinda do ecossistema vira comando" do
    let(:virtual) { create(:device, site: site, name: "Sala", driver: "virtual") }

    def vpoint(capability, **attrs) = create(:point, device: virtual, site: site, capability: capability, **attrs)
    def change(p, attr, value) = Bridges.command!(bridge, p, attr, value)

    it "liga/desliga, nível, cor no liga/desliga irmão, cortina invertida, termostato e fechadura" do
      on = vpoint("onoff", name: "Luz", value: false)
      dim = vpoint("dimmer", name: "Brilho", value: 10)
      color = vpoint("color", name: "Cor", value: { "mode" => "hs", "h" => 0, "s" => 100, "v" => 50 })
      [ on, dim, color ].each { |p| expose(p) }

      expect(change(on, "onOff.onOff", true)).to have_attributes(command: "on", source: "bridge")
      expect(on.reload.value).to be true
      expect(change(on, "onOff.onOff", true)).to be_nil # já está assim: nada a mandar
      change(dim, "levelControl.currentLevel", 127)
      expect(dim.reload.value).to eq(50)
      change(color, "onOff.onOff", false) # lâmpada colorida: desliga pelo ponto liga/desliga da mesma lâmpada
      expect(on.reload.value).to be false
      change(color, "colorControl.currentHue", 85)
      expect(color.reload.value).to include("h" => 120.0, "s" => 100.0)

      blind = create(:device, site: site, name: "Cortina", driver: "virtual")
      pos = create(:point, device: blind, site: site, capability: "setpoint", name: "Posição", unit: "%", min: 0, max: 100, value: 0)
      expose(pos)
      change(pos, "windowCovering.targetPositionLiftPercent100ths", 2500) # Matter 25% fechada = 75% aberta
      expect(pos.reload.value.to_f).to eq(75.0)

      alvo = vpoint("setpoint", name: "Alvo", unit: "°C", min: 16, max: 30, value: 24)
      expose(alvo)
      change(alvo, "thermostat.occupiedCoolingSetpoint", 2150)
      expect(alvo.reload.value.to_f).to eq(21.5)

      gate = vpoint("gate", name: "Portão", risk: "critical", value: "closed")
      expose(gate, risk_confirmed: true)
      expect(change(gate, "doorLock.lockState", 1)).to be_nil # já trancado
      expect(change(gate, "doorLock.lockState", 2)).to have_attributes(command: "pulse")
    end

    it "ponto não exposto, atributo desconhecido e sensor (só leitura) são recusados" do
      on = vpoint("onoff", name: "Luz", value: false)
      expect { change(on, "onOff.onOff", true) }.to raise_error(Points::Command::Error, /não exposto/)
      expose(on)
      expect { change(on, "levelControl.currentLevel", 3) }.to raise_error(Points::Command::Error, /não vale/)
      door = vpoint("contact", name: "Porta")
      expose(door)
      expect { change(door, "booleanState.stateValue", true) }.to raise_error(Points::Command::Error, /não vale/)
    end
  end

  it "ponte falsa registrada pelo PLUGINS funciona sem mudar o núcleo (lista, estado e comando)" do
    fake = Class.new(Bridges::Base) do
      describe key: "fake", title: "Ponte falsa", icon: "chip", description: "teste"
      const_set(:TYPES, { "switch" => { applies: ->(p) { p.capability == "onoff" }, state: ->(_p, v) { { "on" => v } },
                                        commands: { "on" => ->(_p, v) { [ v ? "on" : "off" ] } } } }.freeze)
    end
    stub_const("Bridges::FakeBridge", fake)
    stub_const("Bridges::PLUGINS", Bridges::PLUGINS + %w[FakeBridge])
    virtual = create(:device, site: site, driver: "virtual")
    p = create(:point, device: virtual, site: site, capability: "onoff", name: "Teste", value: false)
    BridgeExposure.create!(site: site, point: p, bridge: "fake")
    expect(Bridges["fake"]).to eq(fake)
    expect(Bridges.devices(fake, Site.where(id: site.id)).first).to include("type" => "switch", "state" => { "on" => false }, "listen" => [ "on" ])
    Bridges.command!(fake, p, "on", true)
    expect(p.reload.value).to be true
    expect(BridgeExposure.new(site: site, point: p, bridge: "outra")).not_to be_valid
  end
end
