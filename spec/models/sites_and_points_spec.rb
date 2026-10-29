require "rails_helper"

RSpec.describe "Locais, papéis e pontos" do
  let(:owner) { create(:user) }
  let(:tenant) { owner.tenant }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  describe Point do
    let(:device) { create(:device, name: "Garagem") }

    it "preenche tipo, gravável, chave e local pela capacidade" do
      point = described_class.create!(device: device, name: "Portão Social", capability: "gate")
      expect(point).to have_attributes(data_type: "enum", writable: true, key: "garagem.portao_social", site_id: device.site_id, quality: "good")
      sensor = described_class.create!(device: device, name: "Temperatura", capability: "measure", unit: " °C ")
      expect(sensor).to have_attributes(data_type: "decimal", writable: false, unit: "°C")
      dimmer = described_class.create!(device: device, name: "Luz", capability: "dimmer")
      expect([ dimmer.min, dimmer.max ]).to eq([ 0, 100 ])
    end

    it "valida capacidade, chave única no local, opções, faixa e o mesmo local" do
      create(:point, device: device, key: "garagem.luz")
      dup = build(:point, device: device, key: "garagem.luz")
      expect(dup).not_to be_valid
      expect(build(:point, device: device, capability: "machine")).not_to be_valid
      expect(build(:point, device: device, key: "Com Espaço")).not_to be_valid
      expect(build(:point, device: device, capability: "enum")).not_to be_valid
      expect(build(:point, device: device, capability: "enum", options_text: "Casa, Fora")).to be_valid
      expect(build(:point, device: device, min: 10, max: 5)).not_to be_valid
      other_area = create(:area)
      expect(build(:point, device: device, area: other_area)).not_to be_valid
      expect(build(:point, device: device, options: [ 1 ])).not_to be_valid
    end

    it "lê as opções do formulário" do
      point = build(:point, options_text: " Casa ,Fora,, Férias ")
      expect(point.options).to eq(%w[Casa Fora Férias])
      expect(point.options_text).to eq("Casa, Fora, Férias")
    end
  end

  describe Area do
    it "a área de cima precisa ser do mesmo local" do
      a = create(:area)
      expect(build(:area, site: a.site, parent: a)).to be_valid
      expect(build(:area, parent: a)).not_to be_valid
      expect(build(:device, site: create(:site), area: a)).not_to be_valid
    end
  end

  describe SiteMembership do
    it "papel mínimo por ação e por risco" do
      expect(described_class.allowed?("guest", :view)).to be true
      expect(described_class.allowed?("guest", :command, risk: "normal")).to be true
      expect(described_class.allowed?("guest", :command, risk: "sensitive")).to be false
      expect(described_class.allowed?("operator", :command, risk: "sensitive")).to be true
      expect(described_class.allowed?("operator", :command, risk: "critical")).to be false
      expect(described_class.allowed?("resident", :manage)).to be false
      expect(described_class.allowed?("technician", :manage)).to be true
      expect(described_class.allowed?("technician", :admin)).to be false
      expect(described_class.allowed?("owner", :admin)).to be true
      expect(described_class.allowed?(nil, :view)).to be false
    end

    it "admin vê tudo; membro vê o local enquanto o acesso vale" do
      site = create(:site)
      create(:site)
      member = create(:user, tenant: tenant, role: "member")
      expect(Site.visible_to(owner).count).to eq(2)
      expect(Site.visible_to(member)).to be_empty
      expect(site.role_for(member)).to be_nil

      m = create(:site_membership, site: site, user: member, role: "guest", expires_at: 1.hour.from_now)
      expect(Site.visible_to(member)).to eq([ site ])
      expect(site.role_for(member)).to eq("guest")
      expect(site.role_for(owner)).to eq("owner")

      m.update!(expires_at: 1.minute.ago)
      expect(Site.visible_to(member)).to be_empty
      expect(build(:site_membership, site: site, user: create(:user))).not_to be_valid
    end
  end
end
