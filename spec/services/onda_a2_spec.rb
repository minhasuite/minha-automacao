require "rails_helper"
require Rails.root.join("supervisor/server").to_s
require Rails.root.join("supervisor/host_probe").to_s

# Onda A2 (paridade HA, grupo 7): serviços do sistema.
RSpec.describe "Onda A2: serviços" do
  describe "A13 supervisor: sonda do host, desligar e logs do servidor" do
    let(:token) { "t" * 40 }
    let(:docker) { FakeDocker.new }
    let(:app) { Supervisor::App.new(docker: docker, token: token, network: "ma-apps", project: "minha-automacao") }

    def req(method, path, body = nil)
      status, _h, out = app.call(Rack::MockRequest.env_for(path, method: method, input: body&.to_json, "HTTP_AUTHORIZATION" => "Bearer #{token}"))
      [ status, JSON.parse(out.join) ]
    end

    before do
      allow(Supervisor).to receive(:log)
      sup = docker.add(labels: { "com.docker.compose.project" => "minha-automacao", "com.docker.compose.service" => "supervisor",
                                 "com.docker.compose.project.working_dir" => "/opt/ma" })
      docker.inspect(sup)["Config"]["Image"] = "ghcr.io/minhasuite/minha-automacao:latest"
      docker.add(labels: { "com.docker.compose.project" => "minha-automacao", "com.docker.compose.service" => "web" })
    end

    it "lê o host num container de uma vez (rede do host, tudo só leitura) e apaga o container" do
      docker.probe_out = %({"hostname":"casa","neighbors":[{"ip":"192.168.0.9","mac":"A4:CF:12:00:00:01","hostname":"shelly1"}]}\n)
      status, body = req("GET", "/system/host")
      expect(status).to eq(200)
      expect(body.dig("data", "hostname")).to eq("casa")
      create = docker.calls.find { |c| c[0] == :post && c[1] == "/containers/create" }
      expect(create[2]["Image"]).to eq("ghcr.io/minhasuite/minha-automacao:latest")
      expect(create[2]["HostConfig"]).to include("NetworkMode" => "host")
      expect(create[2]["HostConfig"]["Binds"]).to all(end_with(":ro"))
      expect(docker.containers([ Supervisor::App::PROBE_LABEL ])).to be_empty
    end

    it "reinicia pelo nsenter e só entrega log dos serviços conhecidos" do
      expect(req("POST", "/system/host/reboot").first).to eq(202)
      create = docker.calls.find { |c| c[1] == "/containers/create" }
      expect(create[2]["Cmd"].last(2)).to eq(%w[systemctl reboot])
      expect(create[2]["HostConfig"]).to include("Privileged" => true, "PidMode" => "host")
      expect(req("GET", "/system/logs?service=web&lines=50").last.dig("data", "lines")).to include("linha 2 (50)")
      expect(req("GET", "/system/logs?service=db").first).to eq(422)
    end

    it "restaura à parte pelo bin/ma-restore (docker:cli, pasta do compose) e só um por vez" do
      expect(req("POST", "/system/restore", file: "../x.sql.gz", source: "backups").first).to eq(422)
      expect(req("POST", "/system/restore", file: "db.sql.gz", source: "etc").first).to eq(422)
      expect(req("POST", "/system/restore", file: "minha_automacao-20261101.sql.gz", source: "storage").first).to eq(202)
      create = docker.calls.find { |c| c[1] == "/containers/create" }
      expect(create[2]["Env"]).to eq([ "DIR=/opt/ma", "FILE=minha_automacao-20261101.sql.gz", "SOURCE=storage" ])
      expect(create[2]["Cmd"].last).to include("restore-status.json", "pg_dump")
      expect(create[3][:name]).to start_with("minha-automacao-restore-")
      expect(req("POST", "/system/restore", file: "outro.sql.gz", source: "backups").first).to eq(409)
      expect(system("sh", "-n", Rails.root.join("bin/ma-restore").to_s)).to be(true)
    end
  end

  describe "A13 sonda" do
    it "lê sistema, rota padrão, vizinhos e portas seriais de uma raiz" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p("#{root}/etc")
        File.write("#{root}/etc/hostname", "casa\n")
        File.write("#{root}/etc/os-release", %(PRETTY_NAME="Debian GNU/Linux 12"\n))
        File.write("#{root}/etc/resolv.conf", "nameserver 192.168.0.1\n")
        allow(HostProbe).to receive(:neighbors).and_return([])
        out = HostProbe.run(root)
        expect(out).to include(hostname: "casa", os: "Debian GNU/Linux 12", dns: [ "192.168.0.1" ], serial: [], usb: [])
        expect(out[:cpus]).to be_positive
      end
      allow(HostProbe).to receive(:read).and_call_original
      allow(HostProbe).to receive(:read).with("/proc/net/route").and_return("Iface\tDestination\tGateway\neth0\t00000000\t0100A8C0\n")
      expect(HostProbe.gateway).to eq("192.168.0.1")
    end
  end

  describe "A19 descoberta por DHCP e USB" do
    let(:host) do
      { "neighbors" => [ { "ip" => "192.168.0.9", "mac" => "A4:CF:12:00:00:01", "hostname" => "shelly1pm-abc.lan" },
                         { "ip" => "192.168.0.10", "mac" => "11:22:33:44:55:66", "hostname" => nil } ],
        "serial" => [ { "id" => "usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus-if00", "path" => "/dev/serial/by-id/usb-ITead_Sonoff", "vid" => "10C4", "pid" => "EA60",
                        "manufacturer" => "ITead", "product" => "Sonoff Zigbee 3.0 USB Dongle Plus" } ] }
    end

    before do
      allow(Host).to receive(:info).and_return(host)
      allow(Mdns).to receive(:browse).and_return([])
      allow(Ssdp).to receive(:search).and_return([])
    end

    it "plugin falso declara dhcp e usb e aparece na descoberta sem mudar o núcleo" do
      fake = Class.new(Integrations::Plugin) do
        describe key: "teste_dhcp", title: "Teste DHCP", icon: "chip", description: "Teste"
        dhcp({ hostname: "shelly*" }, { mac: "112233" })
        usb({ vid: "10c4", pid: "ea60", description: "*zigbee*" })
      end
      stub_const("Integrations::TesteDhcpPlugin", fake)
      expect(fake.discovers?).to be(true)
      found = fake.discover
      expect(found.map { |e| e["host"] }).to eq([ "192.168.0.9", "192.168.0.10", nil ])
      expect(found.first).to include("name" => "shelly1pm-abc")
      expect(found.last).to include("name" => "ITead Sonoff Zigbee 3.0 USB Dongle Plus")
      expect(found.last["txt"]).to include("path" => "/dev/serial/by-id/usb-ITead_Sonoff", "via" => "usb")
    end

    it "os plugins do produto declaram os seus" do
      expect(Integrations::ShellyPlugin.discover.map { |e| e["host"] }).to include("192.168.0.9")
      expect(Integrations::Zigbee2mqttPlugin.discover.map { |e| e.dig("txt", "path") }).to include("/dev/serial/by-id/usb-ITead_Sonoff")
      expect(Integrations::ZwaveJsPlugin.discover).to be_empty
    end

    it "sem supervisor não há host" do
      allow(Host).to receive(:info).and_call_original
      expect(Host.info).to eq({})
      expect(Host.dhcp([ { hostname: "*" } ])).to eq([])
    end
  end
end
