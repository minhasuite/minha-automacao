require "rails_helper"

# Estado real dos sensores (10/11/2026, portão "aberto" por horas): conferência
# periódica da nuvem Tuya, "Redefinir estado" à mão (técnico+, auditado) e o
# sensor parado em "aberto" que vira "desatualizado" com um aviso só.
RSpec.describe "Estado real dos sensores" do # rubocop:disable RSpec/DescribeClass
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }
  let(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Sensor do portão", driver: "tuya_cloud", external_id: "door") } }
  let(:door) do
    within(tenant) do
      create(:point, device: device, name: "Abertura do portão", capability: "contact", writable: false, address: { "dps" => "1", "code" => "doorcontact_state" })
    end
  end
  let(:lamp) { within(tenant) { create(:point, device: device, name: "Luz") } }

  around { |ex| within(tenant) { ex.run } }

  describe Points::Reset do
    it "só sensor; grava pelo report!, vira AuditEvent e a releitura completa não desfaz até o aparelho empurrar" do
      door.report!(true)
      expect { described_class.call(lamp, "true", user: owner) }.to raise_error(Points::Reset::Error)
      door.report!(true)

      described_class.call(door, "false", user: owner)
      expect(door.reload).to have_attributes(value: false, quality: "good")
      expect(described_class.held?(door)).to be true
      audit = AuditEvent.where(auditable_type: "Point", auditable_id: door.id, action: "reset").last
      expect(audit).to have_attributes(user_id: owner.id)
      expect(audit.details).to include("from" => true, "to" => false)
      expect(Points::Timeline.call(door).map(&:title)).to include("Estado redefinido à mão")

      Drivers::TuyaCloud.report(device.reload, { "doorcontact_state" => true }) # conferência: a nuvem também errou
      expect(door.reload.value).to be false
      Drivers::TuyaCloud.report(device.reload, { "doorcontact_state" => true }, push: true) # evento de verdade
      expect(door.reload.value).to be true
      expect(described_class.held?(door)).to be false
    end

    it "enum só aceita uma das opções" do
      mode = create(:point, device: device, name: "Modo", capability: "enum", writable: false, options: %w[a b])
      expect { described_class.call(mode, "c", user: owner) }.to raise_error(Points::Reset::Error)
      described_class.call(mode, "b", user: owner)
      expect(mode.reload.value).to eq("b")
    end
  end

  describe Points::Stale do
    before { door.update!(stale_open_min: 60) }

    it "aberto além do limite: desatualizado, um aviso só; releitura igual mantém; valor novo volta a bom" do
      expect(door.reload.address["stale_open_s"]).to eq(3600)
      expect(door.stale_open_min).to eq(60)
      door.report!(false, at: 3.hours.ago)
      door.report!(true, at: 2.hours.ago) # aberto há 2 h, limite de 1 h

      expect { described_class.tick }.to change { Notification.where(kind: "alerta").count }.by(1)
      expect(door.reload.quality).to eq("stale")
      expect { described_class.tick }.not_to(change { Notification.count })

      door.report!(true) # conferência da nuvem com o mesmo valor
      expect(door.reload.quality).to eq("stale")
      door.report!(false)
      expect(door.reload).to have_attributes(quality: "good", value: false)
    end

    it "fechado, dentro do limite ou sem limite: nada muda" do
      door.report!(true)
      described_class.tick
      expect(door.reload.quality).to eq("good")
      door.update!(stale_open_min: "")
      expect(door.reload.address).not_to have_key("stale_open_s")
    end

    it "roda no RunSchedulesJob" do
      allow(described_class).to receive(:tick)
      RunSchedulesJob.perform_now
      expect(described_class).to have_received(:tick)
    end
  end

  describe Tuya::CloudListener do
    it "conferência periódica relê a nuvem e o erro não derruba a sessão" do
      integration = site.integrations.create!(driver: "tuya", name: "Smart Life", status: "ok", credentials: {}.to_json)
      allow(described_class).to receive(:refresh)
      described_class.reconcile(integration.id)
      expect(described_class).to have_received(:refresh).with(integration)

      allow(described_class).to receive(:refresh).and_raise(Integrations::Error, "Sem conexão")
      expect { described_class.reconcile(integration.id) }.not_to raise_error
    end
  end
end
