require "rails_helper"

# Onda A2 (paridade HA, grupo 7): sistema.
RSpec.describe "Onda A2: sistema" do
  let(:user) { create(:user, role: "owner") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:device) { within(tenant) { create(:device, site: site, name: "Medidor") } }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  describe "A14 ferramenta de estatísticas" do
    let!(:meter) { within(tenant) { create(:point, site: site, device: device, name: "Teste Energia", capability: "measure", unit: "kWh") } }
    let!(:old) { within(tenant) { create(:point, site: site, device: device, name: "Teste Antigo", capability: "measure", history: "none") } }
    let(:hour) { Time.zone.parse("2026-10-10 14:00") }

    before do
      [ hour, hour + 1.hour ].each { |h| ReadingRollup.insert_all([ { point_id: meter.id, bucket: "1h", starts_at: h, sum: 2, count: 1, min: 2, max: 2, avg: 2, last: 2 } ]) }
      ReadingRollup.insert_all([ { point_id: old.id, bucket: "1h", starts_at: hour, sum: 1, count: 1 } ])
      RollupReadingsJob.new.daily(hour.beginning_of_day, hour.end_of_day)
      sign_in
    end

    it "lista, aponta o órfão, ajusta a soma (refaz o dia) e apaga" do
      get "/locais/#{site.id}/ferramentas", params: { aba: "estatisticas" }
      expect(response.body).to include("Teste Energia", "Teste Antigo", "Não grava mais", "2 h")
      expect(within(tenant) { DevTools::Statistics.list(site) }.map(&:issue)).to contain_exactly(nil, "orphan")

      post "/locais/#{site.id}/ferramentas/estatisticas", params: { point_id: meter.id, at: "2026-10-10T14:00", sum: "5,5" }
      expect(flash[:notice]).to include("ajustada")
      day = ReadingRollup.find_by(point_id: meter.id, bucket: "1d")
      expect(day.sum.to_f).to eq(7.5)

      post "/locais/#{site.id}/ferramentas/estatisticas", params: { point_id: meter.id, at: "2026-10-09T03:00", sum: "1" }
      expect(flash[:alert]).to eq("Não há resumo nessa hora.")

      delete "/locais/#{site.id}/ferramentas/estatisticas/#{old.id}"
      expect(ReadingRollup.where(point_id: old.id)).to be_empty
      expect(ReadingRollup.where(point_id: meter.id).count).to eq(3)
    end

    it "membro comum não vê" do
      member = within(tenant) { create(:user, tenant: tenant, role: "member") }
      sign_in(member)
      delete "/locais/#{site.id}/ferramentas/estatisticas/#{old.id}"
      expect(response).to have_http_status(:not_found)
      expect(ReadingRollup.where(point_id: old.id)).to exist
    end
  end

  describe "A13 hardware e rede do host" do
    let(:host) do
      { "hostname" => "casa", "os" => "Debian GNU/Linux 12", "kernel" => "6.1.0", "arch" => "x86_64", "cpu" => "Intel N100", "cpus" => 4,
        "memory_mb" => 8000, "memory_free_mb" => 5000, "uptime_s" => 90_000, "gateway" => "192.168.0.1", "dns" => [ "192.168.0.1" ],
        "interfaces" => [ { "name" => "enp1s0", "mac" => "aa:bb:cc:dd:ee:ff", "state" => "up", "ipv4" => [ "192.168.0.5" ], "ipv6" => [] } ],
        "neighbors" => [ {} ], "serial" => [ { "id" => "usb-zig", "path" => "/dev/serial/by-id/usb-zig", "vid" => "10C4", "pid" => "EA60", "product" => "Teste Zigbee" } ],
        "usb" => [ { "vid" => "8087", "pid" => "0026", "manufacturer" => "Intel", "product" => "Bluetooth" } ] }
    end

    it "mostra máquina, rede e USB ao dono; reinicia com auditoria; sem supervisor explica" do
      sign_in
      get "/configuracoes/hardware"
      expect(response.body).to include("Hardware e rede", "Esta instalação roda sem o supervisor")

      allow(Apps::Supervisor).to receive(:configured?).and_return(true)
      allow(Apps::Supervisor).to receive(:request).with(:get, "/system/host").and_return("data" => host)
      get "/configuracoes/hardware", params: { atualizar: 1 }
      expect(response.body).to include("Debian GNU/Linux 12", "Intel N100 · 4 núcleos", "enp1s0", "192.168.0.5", "Teste Zigbee", "10C4:EA60", "Outros aparelhos USB (1)")

      expect(Apps::Supervisor).to receive(:request).with(:post, "/system/host/reboot").and_return({})
      post "/configuracoes/hardware/reboot"
      expect(flash[:notice]).to eq("Reiniciando a máquina.")
      expect(within(tenant) { AuditEvent.where(action: "host.reboot").count }).to eq(1)
      post "/configuracoes/hardware/formatar"
      expect(response).to have_http_status(:not_found)
    end

    it "só o dono" do
      sign_in(within(tenant) { create(:user, tenant: tenant, role: "admin") })
      get "/configuracoes/hardware"
      expect(response).to redirect_to("/")
    end
  end
end
