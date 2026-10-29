require "rails_helper"

RSpec.describe "Jobs do histórico e dos comandos" do
  let(:tenant) { create(:tenant) }
  let(:device) { create(:device) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def add(point, at, value) = Reading.insert_all!([ { point_id: point.id, at: Time.zone.parse(at), value: value } ], returning: false)

  it "ExecuteCommandJob confirma, expira o velho e marca falha do driver" do
    lamp = create(:point, device: device)
    cmd = Command.create!(site: lamp.site, point: lamp, command: "on", source: "automation")
    ExecuteCommandJob.perform_now(cmd.id)
    expect(cmd.reload).to have_attributes(status: "confirmed", sent_at: be_present, confirmed_at: be_present)
    expect(lamp.reload.value).to be true
    ExecuteCommandJob.perform_now(cmd.id) # já confirmado: nada muda
    expect(cmd.reload.status).to eq("confirmed")

    old = Command.create!(site: lamp.site, point: lamp, command: "off", source: "api", created_at: 5.minutes.ago)
    ExecuteCommandJob.perform_now(old.id)
    expect(old.reload.status).to eq("expired")
    expect(lamp.reload.value).to be true

    allow_any_instance_of(Drivers::Virtual).to receive(:execute).and_raise(IOError, "aparelho não respondeu") # rubocop:disable RSpec/AnyInstance
    bad = Command.create!(site: lamp.site, point: lamp, command: "off", source: "web")
    ExecuteCommandJob.perform_now(bad.id)
    expect(bad.reload).to have_attributes(status: "failed", error: "aparelho não respondeu")
  end

  it "comando de driver de verdade vai para a fila" do
    lamp = create(:point, device: device)
    allow(Drivers).to receive(:supported?).and_return(true)
    device.update!(driver: "tuya_local")
    expect { Points::Command.call(lamp, "on", source: "api") }.to have_enqueued_job(ExecuteCommandJob)
  end

  it "RollupReadingsJob resume por hora e dia, com tempo ligado" do
    temp = create(:point, device: device, capability: "measure")
    lamp = create(:point, device: device)
    add(temp, "2026-10-29 10:10", 20)
    add(temp, "2026-10-29 10:40", 22)
    add(temp, "2026-10-29 11:05", 30)
    add(lamp, "2026-10-29 09:00", 1)
    add(lamp, "2026-10-29 10:15", 0)
    add(lamp, "2026-10-29 11:45", 1)

    2.times { RollupReadingsJob.perform_now(Time.zone.parse("2026-10-29 12:00")) }

    hour = ->(p, at) { ReadingRollup.find_by(point_id: p.id, bucket: "1h", starts_at: Time.zone.parse(at)) }
    expect(hour.(temp, "2026-10-29 10:00")).to have_attributes(min: 20, max: 22, avg: 21, last: 22, count: 2)
    expect(hour.(lamp, "2026-10-29 09:00").on_seconds).to eq(3600)
    expect(hour.(lamp, "2026-10-29 10:00").on_seconds).to eq(900)
    expect(hour.(lamp, "2026-10-29 11:00").on_seconds).to eq(900)
    day = ReadingRollup.find_by(point_id: temp.id, bucket: "1d")
    expect(day).to have_attributes(starts_at: Time.zone.parse("2026-10-29 00:00"), min: 20, max: 30, last: 30, count: 3)
    expect(day.avg.round(2)).to eq(24)
    expect(ReadingRollup.find_by(point_id: lamp.id, bucket: "1d").on_seconds).to eq(3600 + 900 + 900)
  end

  it "ReadingsMaintenanceJob aplica a retenção do ponto e de comandos e eventos" do
    short = create(:point, device: device, capability: "measure", retention_days: 7)
    add(short, 10.days.ago.to_s, 1)
    add(short, 1.day.ago.to_s, 2)
    Command.create!(site: short.site, point: short, command: "on", source: "api", created_at: 400.days.ago)
    Event.create!(site: short.site, point: short, kind: "quality", at: 400.days.ago)
    ReadingsMaintenanceJob.perform_now
    expect(Reading.where(point_id: short.id).pluck(:value)).to eq([ 2 ])
    expect(Command.count + Event.count).to eq(0)
  end
end
