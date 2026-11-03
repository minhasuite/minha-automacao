require "rails_helper"
require Rails.root.join("supervisor/server").to_s

# resto: o que passa pelo supervisor (rede do host, apps de terceiros) com Docker de mentira.
RSpec.describe "Paridade: resto no supervisor" do
  let(:token) { "t" * 40 }
  let(:docker) { FakeDocker.new }
  let(:app) { Supervisor::App.new(docker: docker, token: token, network: "ma-apps", project: "minha-automacao") }

  def req(method, path, body = nil)
    status, _h, out = app.call(Rack::MockRequest.env_for(path, method: method, input: body&.to_json, "HTTP_AUTHORIZATION" => "Bearer #{token}"))
    [ status, JSON.parse(out.join) ]
  end

  def cmds = docker.calls.select { |c| c[1] == "/containers/create" }.map { |c| c[2]["Cmd"] }

  before do
    allow(Supervisor).to receive(:log)
    sup = docker.add(labels: { "com.docker.compose.project" => "minha-automacao", "com.docker.compose.service" => "supervisor" })
    docker.inspect(sup)["Config"]["Image"] = "ghcr.io/minhasuite/minha-automacao:latest"
  end

  describe "IP e Wi-Fi do host (7.3)" do
    it "IP fixo vira nmcli com argumentos separados (sem shell) e valida tudo antes" do
      docker.probe_out = "Wired connection 1\n"
      status, = req("POST", "/system/host/network", { interface: "eth0", mode: "static", address: "192.168.0.10/24", gateway: "192.168.0.1", dns: %w[1.1.1.1] })
      expect(status).to eq(202)
      mod = cmds.find { |c| c.include?("modify") }
      expect(mod.drop_while { |a| a != "nmcli" }).to eq([ "nmcli", "connection", "modify", "Wired connection 1", "ipv4.method", "manual", "ipv4.addresses", "192.168.0.10/24",
                                                          "ipv4.gateway", "192.168.0.1", "ipv4.dns", "1.1.1.1" ])
      expect(cmds.last.last(3)).to eq([ "connection", "up", "Wired connection 1" ])

      n = cmds.size
      expect(req("POST", "/system/host/network", { interface: "eth0; reboot", mode: "dhcp" }).first).to eq(422)
      expect(req("POST", "/system/host/network", { interface: "eth0", mode: "static", address: "999.1.1.1/24", gateway: "x" }).first).to eq(422)
      expect(cmds.size).to eq(n + 1) # só o "device show" da interface válida, nada aplicado
    end

    it "Wi-Fi: lista as redes e conecta; senha curta é recusada" do
      docker.probe_out = "Casa:80:WPA2\nVizinho\\:5G:40:WPA2\nAberta:20:\n"
      status, body = req("GET", "/system/host/wifi")
      expect(status).to eq(200)
      expect(body["data"].map { |w| w["ssid"] }).to eq([ "Casa", "Vizinho:5G", "Aberta" ])
      expect(req("POST", "/system/host/wifi", { ssid: "Casa", password: "123" }).first).to eq(422)
      expect(req("POST", "/system/host/wifi", { ssid: "Casa", password: "12345678", interface: "wlan0" }).first).to eq(202)
      expect(cmds.last.last(8)).to eq(%w[device wifi connect Casa password 12345678 ifname wlan0])
    end

    it "sem NetworkManager explica (rede)" do
      docker.probe_out = "exec: \"nmcli\": executable file not found in $PATH"
      expect(req("POST", "/system/host/network", { interface: "eth0", mode: "dhcp" }).first).to eq(422)
    end
  end

  describe "apps de repositório de terceiros (7.13)" do
    let(:digest) { "sha256:#{'a' * 64}" }
    let(:manifest) do
      { "name" => "Teste App", "category" => "Teste", "icon" => "cube", "description" => "Teste", "image" => "ghcr.io/teste/app", "version" => "1.0",
        "digest" => digest, "network" => "apps", "ports" => [ { "container" => 8080, "host" => 18_080 } ] }
    end

    it "instala com a imagem pelo digest, guarda o manifesto no container e lista depois" do
      expect(req("POST", "/apps/teste_app/install", { manifest: manifest.except("digest") })).to match([ 422, include("error" => /digest/) ])
      expect(req("POST", "/apps/teste_app/install", { manifest: manifest.merge("server_env" => { "X" => "MQTT_PASSWORD" }) }).first).to eq(422)
      expect(req("POST", "/apps/mosquitto/install", { manifest: manifest }).first).to eq(422) # app do sistema/produto não é trocado
      expect(req("POST", "/apps/nao_existe/install", {}).first).to eq(404)

      expect(req("POST", "/apps/teste_app/install", { manifest: manifest }).first).to eq(202)
      Timeout.timeout(2) { sleep 0.02 until docker.containers([ "#{AppCatalog::LABEL}=teste_app" ]).any? }
      create = docker.calls.find { |c| c[1] == "/containers/create" }[2]
      expect(create["Image"]).to eq("ghcr.io/teste/app@#{digest}")
      expect(create["HostConfig"]).to include("Privileged" => false, "NetworkMode" => "ma-apps")
      expect(JSON.parse(create["Labels"]["minha-automacao.manifest"])).to include("digest" => digest)
      expect(req("GET", "/apps").last["data"].map { |a| a["key"] }).to include("teste_app")
      expect(req("GET", "/apps/teste_app").last.dig("data", "installed")).to be true
    end
  end
end
