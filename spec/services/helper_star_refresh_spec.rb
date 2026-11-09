require "rails_helper"

RSpec.describe "Helpers de origem \"*\" com debounce" do
  include ActiveJob::TestHelper

  let(:tenant) { create(:tenant) }
  let(:site) { within(tenant) { create(:site, tenant: tenant) } }

  def within(t, &) = ActsAsTenant.with_tenant(t, &)

  before { HelperTypes.instance_variable_get(:@star_at).clear }

  it "agenda uma rodada por local e não refaz os templates dentro do comando" do
    within(tenant) do
      device = create(:device, site: site)
      lamp = create(:point, device: device, capability: "onoff", value: false)
      expect(HelperTypes::Template).not_to receive(:refresh!)
      expect {
        lamp.report!(true)
        lamp.report!(false)
      }.to have_enqueued_job(HelperStarRefreshJob).with(site.id).exactly(:once)
    end
  end

  it "o job refaz os helpers \"*\" do local" do
    within(tenant) do
      helper = HelperTypes.device(site).points.create!(site: site, name: "Ligados", key: "helpers.ligados", capability: "measure",
                                                         helper: "template", address: { "kind" => "number", "expr" => "1 + 1", "sources" => [ "*" ] })
      HelperStarRefreshJob.perform_now(site.id)
      expect(helper.reload.value.to_f).to eq(2.0)
    end
  end

  it "plugin com erro no tick não derruba os outros" do
    bad = Class.new { def self.tick(_) = raise("quebrou") }
    good = Class.new { def self.tick(_) = (@ran = true); def self.ran = @ran }
    allow(Integrations).to receive(:plugins).and_return([ bad, good ])
    expect { Integrations.tick }.not_to raise_error
    expect(good.ran).to be(true)
  end

  it "tick do Bluetooth roda sem empresa atual" do
    ActsAsTenant.current_tenant = nil
    expect { Integrations::BluetoothPlugin.tick(Time.current) }.not_to raise_error
  end
end

RSpec.describe Automations::Context do
  it "reaproveita a carga dos pontos entre consultas do mesmo texto" do
    tenant = create(:tenant)
    ActsAsTenant.with_tenant(tenant) do
      site = create(:site, tenant: tenant)
      device = create(:device, site: site)
      create(:point, device: device, capability: "onoff", value: true)
      ctx = described_class.new(site: site)
      loads = 0
      counter = ->(*, payload) { loads += 1 if payload[:sql].to_s.match?(/FROM "points"/) && payload[:name] != "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        3.times { expect(ctx.query("capability=onoff state=on").size).to eq(1) }
      end
      expect(loads).to eq(1)
    end
  end
end
