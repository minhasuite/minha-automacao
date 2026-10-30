require "rails_helper"
require Rails.root.join("supervisor/server").to_s

# Supervisor (supervisor/server.rb) com um Docker de mentira: só apps do
# catálogo, só containers com o label, token obrigatório.
RSpec.describe Supervisor::App do
  before { allow(Supervisor).to receive(:log) }

  let(:token) { "t" * 40 }
  let(:docker) { FakeDocker.new }
  let(:app) { described_class.new(docker: docker, token: token, network: "ma-apps", project: "minha-automacao", env: { "MQTT_PASSWORD" => "mq", "DB_PASSWORD" => "nunca" }) }

  def req(method, path, body = nil, auth: token)
    env = Rack::MockRequest.env_for(path, method: method, input: body&.to_json, "HTTP_AUTHORIZATION" => "Bearer #{auth}")
    status, _h, out = app.call(env)
    [ status, JSON.parse(out.join) ]
  end

  def wait_idle(key)
    50.times do
      break unless req("GET", "/apps/#{key}").last.dig("data", "busy")

      sleep 0.02
    end
  end

  it "exige o token (menos /health) e só conhece apps do catálogo" do
    expect(req("GET", "/health", auth: "").first).to eq(200)
    expect(req("GET", "/apps", auth: "errado").first).to eq(401)
    expect(described_class.new(docker: docker, token: "", network: "x", project: "y").call(Rack::MockRequest.env_for("/apps")).first).to eq(401)
    expect(req("GET", "/apps/nao_existe").first).to eq(404)
    expect(req("GET", "/outra").first).to eq(404)
    expect(req("PATCH", "/apps/uptime_kuma/x").first).to eq(404)
  end

  it "lista o catálogo com o estado de cada app; sistema pelo serviço do compose" do
    docker.add(labels: { "com.docker.compose.project" => "minha-automacao", "com.docker.compose.service" => "mosquitto" })
    docker.add(labels: { "com.docker.compose.project" => "outro", "com.docker.compose.service" => "go2rtc" })
    docker.add(labels: { "tunel" => "1" }) # container de fora: nunca aparece
    status, body = req("GET", "/apps")
    expect(status).to eq(200)
    by_key = body["data"].index_by { |s| s["key"] }
    expect(by_key["mosquitto"]).to include("installed" => true, "system" => true, "state" => "running", "version" => "2.0.20", "memory_mb" => 42.5)
    expect(by_key["go2rtc"]["installed"]).to be(false)
    expect(by_key["uptime_kuma"]["installed"]).to be(false)
  end

  it "instala em segundo plano, inicia, para, reinicia, lê o log, reconfigura, atualiza e desinstala" do
    status, body = req("POST", "/apps/uptime_kuma/install", { boot: true })
    expect([ status, body.dig("data", "busy") ]).to eq([ 202, "Instalando" ])
    wait_idle("uptime_kuma")
    st = req("GET", "/apps/uptime_kuma").last["data"]
    expect(st).to include("installed" => true, "state" => "running", "boot" => true, "watchdog" => true, "version" => "1.23.16")
    expect(docker.pulled).to eq([ "louislam/uptime-kuma:1.23.16" ])
    expect(docker.volumes.keys).to eq([ "ma-app-uptime_kuma-data" ])
    create = docker.calls.find { |c| c[1] == "/containers/create" }
    expect(create[3]).to eq(name: "ma-app-uptime_kuma")
    expect(create[2]["Env"].join).not_to include("nunca")
    expect(req("POST", "/apps/uptime_kuma/install").first).to eq(409)

    docker.containers_by_id.values.last["State"]["Health"] = { "Status" => "unhealthy" }
    stopped = req("POST", "/apps/uptime_kuma/stop").last["data"]
    expect(stopped.values_at("state", "health")).to eq([ "exited", nil ])
    expect(req("POST", "/apps/uptime_kuma/start").last.dig("data", "state")).to eq("running")
    expect(req("POST", "/apps/uptime_kuma/restart").first).to eq(200)
    expect(req("POST", "/apps/uptime_kuma/kill").first).to eq(422)
    expect(req("GET", "/apps/uptime_kuma/logs?lines=5000").last.dig("data", "lines")).to include("linha 2 (1000)")

    expect(req("PUT", "/apps/uptime_kuma/config", { boot: false, watchdog: true }).last["data"]).to include("boot" => false, "watchdog" => true)
    expect(req("PUT", "/apps/uptime_kuma/config", { options: {} }).first).to eq(202)
    wait_idle("uptime_kuma")
    expect(req("GET", "/apps/uptime_kuma").last.dig("data", "watchdog")).to be(true)

    allow(AppCatalog.find("uptime_kuma")).to receive(:version).and_return("2.0.0")
    expect(req("POST", "/apps/uptime_kuma/update").first).to eq(202)
    wait_idle("uptime_kuma")
    expect(req("GET", "/apps/uptime_kuma").last.dig("data", "version")).to eq("2.0.0")

    expect(req("DELETE", "/apps/uptime_kuma?keep_data=1").last.dig("data", "installed")).to be(false)
    expect(docker.volumes).not_to be_empty
    req("POST", "/apps/uptime_kuma/install", {})
    wait_idle("uptime_kuma")
    req("DELETE", "/apps/uptime_kuma")
    expect(docker.volumes).to be_empty
    expect(req("DELETE", "/apps/uptime_kuma").first).to eq(404)
  end

  it "valida as opções pelo schema e guarda segredo só no env do container" do
    status, body = req("POST", "/apps/zigbee2mqtt/install", { options: { serial_port: "/etc/shadow" } })
    expect([ status, body["errors"].keys ]).to eq([ 422, [ "serial_port" ] ])

    req("POST", "/apps/code_server/install", { options: { password: "segredo123" } })
    wait_idle("code_server")
    c = docker.containers([ "#{AppCatalog::LABEL}=code_server" ]).first
    expect(c.dig("Config", "Env")).to include("PASSWORD=segredo123")
    expect(c.dig("Config", "Labels", "minha-automacao.options")).not_to include("segredo123")
    req("PUT", "/apps/code_server/config", { options: { password: "" } })
    wait_idle("code_server")
    c = docker.containers([ "#{AppCatalog::LABEL}=code_server" ]).first
    expect(c.dig("Config", "Env")).to include("PASSWORD=segredo123")

    req("POST", "/apps/zigbee2mqtt/install", { options: { serial_port: "/dev/ttyUSB0" } })
    wait_idle("zigbee2mqtt")
    c = docker.containers([ "#{AppCatalog::LABEL}=zigbee2mqtt" ]).first
    expect(c.dig("Config", "Env")).to include("ZIGBEE2MQTT_CONFIG_MQTT_PASSWORD=mq")
    create = docker.calls.reverse.find { |x| x[1] == "/containers/create" }
    expect(create[2].dig("HostConfig", "NetworkMode")).to eq("ma-apps")
  end

  it "app do sistema só reinicia e mostra log; nada de instalar, parar ou desinstalar" do
    docker.add(labels: { "com.docker.compose.project" => "minha-automacao", "com.docker.compose.service" => "go2rtc" })
    expect(req("POST", "/apps/go2rtc/restart").first).to eq(200)
    expect(req("POST", "/apps/go2rtc/stop").first).to eq(422)
    expect(req("POST", "/apps/go2rtc/install").first).to eq(422)
    expect(req("PUT", "/apps/go2rtc/config", {}).first).to eq(422)
    expect(req("POST", "/apps/go2rtc/update").first).to eq(422)
    expect(req("DELETE", "/apps/go2rtc").first).to eq(422)
    expect(req("GET", "/apps/go2rtc/logs").first).to eq(200)
  end

  it "responde 404 para app não instalado e anota a falha da instalação" do
    %w[stop].each { |a| expect(req("POST", "/apps/node_red/#{a}").first).to eq(404) }
    expect(req("PUT", "/apps/node_red/config", {}).first).to eq(404)
    expect(req("POST", "/apps/node_red/update").first).to eq(404)
    expect(req("GET", "/apps/node_red/logs").first).to eq(422)

    allow(docker).to receive(:pull).and_raise(Supervisor::Error, "manifest unknown")
    req("POST", "/apps/node_red/install", {})
    sleep 0.05
    expect(req("GET", "/apps/node_red").last.dig("data", "error")).to eq("manifest unknown")
    allow(docker).to receive(:containers).and_raise(ArgumentError)
    expect(req("GET", "/apps").first).to eq(500)
  end

  it "watchdog reinicia app sem saúde com política de reinício" do
    sick = docker.add(labels: { AppCatalog::LABEL => "node_red" }, health: "unhealthy", policy: "on-failure")
    docker.add(labels: { AppCatalog::LABEL => "esphome" }, health: "unhealthy", policy: "no")
    docker.add(labels: { AppCatalog::LABEL => "frigate" }, health: "unhealthy", policy: "unless-stopped", state: "exited")
    app.watchdog!
    expect(docker.calls.map { |c| c[1] }).to eq([ "/containers/#{sick}/restart" ])
  end
end

RSpec.describe Supervisor::Docker do
  # Servidor HTTP de mentira num socket unix: responde pelo caminho pedido.
  def serve(responses)
    path = Rails.root.join("tmp/docker-test-#{SecureRandom.hex(4)}.sock").to_s
    server = UNIXServer.new(path)
    thread = Thread.new do
      loop do
        s = server.accept
        line = s.gets
        len = 0
        while (h = s.gets) && h != "\r\n"
          len = h.split(":").last.to_i if h.downcase.start_with?("content-length")
        end
        s.read(len) if len.positive?
        code, body = responses.find { |k, _| line.include?(k) }&.last || [ 200, "{}" ]
        s.write("HTTP/1.1 #{code} OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        s.close
      end
    end
    yield described_class.new(path)
  ensure
    thread&.kill
    server&.close
    FileUtils.rm_f(path)
  end

  it "fala HTTP pelo socket: lista, puxa imagem, lê log multiplexado e memória" do
    frame = ->(text) { [ 1, 0, 0, 0, text.bytesize ].pack("CCCCN") + text }
    serve("/containers/json" => [ 200, '[{"Id":"a"}]' ], "/images/create?fromImage=x&tag=1" => [ 200, "{\"status\":\"ok\"}\n" ],
          "/images/create?fromImage=bad" => [ 200, "{\"error\":\"denied\"}\n" ], "/logs" => [ 200, frame.call("olá\n") + frame.call("fim\n") ],
          "/stats" => [ 200, '{"memory_stats":{"usage":10485760,"stats":{"inactive_file":0}}}' ],
          "/containers/z/json" => [ 404, '{"message":"no such container"}' ], "/containers/e/json" => [ 500, '{"message":"boom"}' ]) do |d|
      expect(d.containers([ "x" ])).to eq([ { "Id" => "a" } ])
      expect { d.pull("x:1") }.not_to raise_error
      expect { d.pull("bad:1") }.to raise_error(Supervisor::Error, "denied")
      expect(d.logs("a", 10)).to eq("olá\nfim\n")
      expect(d.memory_mb("a")).to eq(10.0)
      expect(d.call(:get, "/containers/z/json").first).to eq(404)
      expect { d.inspect("e") }.to raise_error(Supervisor::Error, "boom")
    end
  end
end
