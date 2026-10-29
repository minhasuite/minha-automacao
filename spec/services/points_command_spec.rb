require "rails_helper"

RSpec.describe Points::Command do
  let(:tenant) { create(:tenant) }
  let(:device) { create(:device) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def point(**attrs) = create(:point, device: device, **attrs)
  def run(p, command, value = nil) = described_class.call(p, command, value, source: "api").point.reload.value

  def expect_error(code, &)
    expect(&).to raise_error(described_class::Error) { |e| expect(e.code).to eq(code) }
  end

  it "liga, desliga e alterna um ponto virtual, marcando quando mudou" do
    p = point
    travel_to(Time.zone.parse("2026-10-29 10:00")) { expect(run(p, "on")).to be true }
    expect(p.reload.changed_at).to eq(Time.zone.parse("2026-10-29 10:00"))
    travel_to(Time.zone.parse("2026-10-29 11:00")) { run(p, "on") }
    expect(p.reload.changed_at).to eq(Time.zone.parse("2026-10-29 10:00"))
    expect(p.reported_at).to eq(Time.zone.parse("2026-10-29 11:00"))
    expect(run(p, "toggle")).to be false
    expect(run(p, "off")).to be false
  end

  it "valor numérico na faixa, seleção, texto, portão e botão" do
    expect(run(point(capability: "dimmer"), "set", "42,4")).to eq(42)
    expect(run(point(capability: "setpoint", min: 1, max: 30), "set", "22.5")).to eq(22.5)
    expect(run(point(capability: "enum", options: %w[Casa Fora]), "select", "Fora")).to eq("Fora")
    expect(run(point(capability: "text"), "set", "Olá")).to eq("Olá")
    gate = point(capability: "gate")
    expect(run(gate, "pulse")).to eq("open")
    expect(run(gate, "pulse")).to eq("closed")
    button = point(capability: "command")
    described_class.call(button, "press", source: "web")
    expect(button.reload.reported_at).to be_present
  end

  it "recusa o que não serve" do
    expect_error(:invalid_value) { run(point(capability: "dimmer"), "set", "120") }
    expect_error(:invalid_value) { run(point(capability: "dimmer"), "set", "abc") }
    expect_error(:invalid_value) { run(point(capability: "enum", options: %w[Casa]), "select", "Praia") }
    expect_error(:invalid_value) { run(point(capability: "text"), "set", "x" * 256) }
    expect_error(:unsupported_command) { run(point, "set", "1") }
    expect_error(:unsupported_command) { run(point(capability: "color"), "set_color") }
    expect_error(:not_writable) { run(point(capability: "measure"), "set", "1") }
    expect_error(:point_disabled) { run(point(disabled: true), "on") }
    real = create(:point, device: create(:device, site: device.site, driver: "modbus_tcp"))
    expect_error(:driver_unavailable) { run(real, "on") }
  end
end
