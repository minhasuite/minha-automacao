require "rails_helper"

# Comando a caminho do aparelho: a tela mostra o estado pedido com "Enviando…" até o
# aparelho responder (o valor muda), o comando falhar ou passar o tempo de espera.
RSpec.describe Points::Inflight do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site) } }
  let!(:device) { within(tenant) { create(:device, site: site) } }
  let!(:lamp) { within(tenant) { create(:point, device: device, value: false, changed_at: 1.minute.ago) } }
  let!(:dimmer) { within(tenant) { create(:point, device: device, capability: "dimmer", value: 40, changed_at: 1.minute.ago) } }
  let!(:gate) { within(tenant) { create(:point, device: device, capability: "gate", value: "closed", changed_at: 1.minute.ago) } }

  def command(point, cmd, status: "sent", value: nil, **attrs)
    within(tenant) { Command.create!(site: site, point: point, command: cmd, value: value, source: "web", status: status, **attrs) }
  end

  def state(*points) = within(tenant) { described_class.for(points) }

  it "enviando: mostra o estado pedido (ligar, alternar, ajustar) até o valor mudar" do
    command(lamp, "toggle")
    command(dimmer, "set", value: 80, status: "pending")
    expect(state(lamp, dimmer)).to eq(lamp.id => { "pending" => true, "expect" => true }, dimmer.id => { "pending" => true, "expect" => 80 })

    within(tenant) { lamp.report!(true) }
    expect(state(lamp.reload)).to eq({})
  end

  it "pedir o que já está não espera nada; comando sem estado (portão) só enquanto vai na fila" do
    command(lamp, "off")
    expect(state(lamp)).to eq({})
    command(gate, "pulse", status: "confirmed", confirmed_at: Time.current)
    expect(state(gate)).to eq({})
    command(gate, "pulse", status: "pending")
    expect(state(gate)).to eq(gate.id => { "pending" => true })
  end

  it "confirmado espera o aviso do aparelho por um tempo; falha fica à vista um tempo; velho some" do
    command(lamp, "on", status: "confirmed", confirmed_at: 5.seconds.ago)
    expect(state(lamp)[lamp.id]).to include("pending" => true)
    travel 20.seconds do
      expect(state(lamp)).to eq({})
    end

    command(dimmer, "set", value: 10, status: "failed", error: "sem resposta")
    expect(state(dimmer)).to eq(dimmer.id => { "failed" => "sem resposta" })
    travel 2.minutes do
      expect(state(dimmer)).to eq({})
    end
  end

  it "desenha com o valor pedido e devolve o valor de verdade" do
    described_class.as_expected(lamp, { "expect" => true }) { expect(lamp.value).to be(true) }
    expect(lamp.value).to be(false)
    expect(lamp).not_to be_changed
  end
end
