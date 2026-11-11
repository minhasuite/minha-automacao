require "rails_helper"
require "socket"

# Ondas de evolução (apps): campos novos do manifesto e as integrações dos
# apps do catálogo. WebMock em todo HTTP; Wyoming e MQTT só com servidor ou
# mensagem falsos; nenhum aviso de verdade.
RSpec.describe "Aplicativos novos e suas integrações" do
  include ActiveJob::TestHelper

  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, latitude: -15.80, longitude: -47.90) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def json(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  def form(h) = ActionController::Parameters.new(h)

  def add(plugin, h)
    o = plugin.setup(site, form(h))
    expect(o.alert).to be_nil
    Integrations.adopt!(o.integration, o.integration.found.to_h { |e| [ e["id"], "" ] })
    o.integration
  end

  def manifest(extra = {}, third_party: false)
    data = { "name" => "Teste", "category" => "X", "icon" => "cube", "description" => "d", "image" => "org/teste", "version" => "1.0.0", "network" => "bridge" }
    data["digest"] = "sha256:#{'a' * 64}" if third_party
    third_party ? AppCatalog.third_party("teste_x", data.merge(extra)) : AppCatalog::Manifest.new("teste", data.merge(extra))
  end

  describe "manifesto" do
    it "comando, NET_ADMIN, sysctls de rede, DNS na 53, memória e ligação entram no container; o resto é recusado" do
      m = manifest({ "command" => %w[serve], "cap_add" => %w[NET_ADMIN], "sysctls" => { "net.ipv4.ip_forward" => "1" }, "ram_mb" => 2048,
                     "ports" => [ { "container" => 53, "host" => 53, "protocol" => "udp" } ], "connect" => { "ai" => "ollama", "base_url" => "http://{host}:11434" } })
      body = m.container_body({}, network: "bridge", restart: "no")
      expect(body["Cmd"]).to eq(%w[serve])
      expect(body["HostConfig"]).to include("CapAdd" => %w[NET_ADMIN], "Sysctls" => { "net.ipv4.ip_forward" => "1" }, "Privileged" => false)
      expect([ m.heavy?, m.connect_values("192.168.0.9") ]).to eq([ true, { "base_url" => "http://192.168.0.9:11434" } ])
      expect(manifest.container_body({}, network: "bridge", restart: "no")).not_to have_key("Cmd")
      [ { "cap_add" => %w[SYS_ADMIN] }, { "cap_add" => "NET_ADMIN" }, { "sysctls" => { "kernel.shmmax" => "1" } }, { "command" => "sh -c x" },
        { "command" => [ "a\nb" ] }, { "ram_mb" => 0 }, { "ports" => [ { "container" => 22, "host" => 22 } ] },
        { "connect" => { "integration" => "x", "ai" => "y" } }, { "connect" => { "shell" => "x" } }, { "connect" => { "ai" => "ollama", "x" => [ 1 ] } } ].each do |bad|
        expect { manifest(bad) }.to raise_error(AppCatalog::Invalid), bad.inspect
      end
      [ { "cap_add" => %w[NET_ADMIN] }, { "connect" => { "ai" => "ollama" } }, { "ports" => [ { "container" => 53, "host" => 53 } ] } ].each do |bad|
        expect { manifest(bad, third_party: true) }.to raise_error(AppCatalog::Invalid), bad.inspect
      end
    end

    it "os apps novos estão no catálogo, com memória marcada e a ligação apontando para plugin que existe" do
      keys = %w[adguard_home speedtest_tracker vaultwarden syncthing wg_easy wyoming_whisper wyoming_piper ollama compreface double_take
                owntracks_recorder espresense_companion scrypted influxdb grafana ntfy]
      expect(AppCatalog.all.map(&:key)).to include(*keys)
      keys.each { |k| expect(AppCatalog.find(k).ram_mb).to be_positive, k }
      expect(AppCatalog.all.select(&:heavy?).map(&:key)).to include("compreface", "ollama")
      AppCatalog.all.filter_map(&:connect).each do |c|
        expect(c["ai"] ? Ai.provider(c["ai"]) : Integrations.plugin(c["integration"])).to be_present, c.inspect
      end
      expect(AppCatalog.find("wg_easy").cap_add).to eq(%w[NET_ADMIN])
      expect(AppCatalog.find("ntfy").command).to eq(%w[serve])
    end
  end

  describe "Speedtest Tracker" do
    it "último teste da API vira download, upload, latência e a hora" do
      stub_request(:get, "http://192.0.2.7:8765/api/v1/results/latest").with(headers: { "Authorization" => "Bearer tok-teste" })
        .to_return(json("data" => { "ping" => 12.345, "download_bits" => 312_400_000, "upload" => 5_000_000, "created_at" => "2026-11-10T10:00:00Z" }))
      i = add(Integrations::SpeedtestTrackerPlugin, url: "http://192.0.2.7:8765", token: "tok-teste")
      p = i.devices.first.points.reload.index_by { |x| x.address["field"] }
      expect([ p["download"].value, p["upload"].value, p["ping"].value ]).to eq([ 312.4, 40.0, 12.3 ])
      expect(Time.zone.parse(p["last_test"].value)).to eq(Time.utc(2026, 11, 10, 10))
      expect(p["download"].unit).to eq("Mbit/s")

      stub_request(:get, "http://192.0.2.8:8765/api/v1/results/latest").to_return(json("message" => "no results"))
      expect(Integrations::SpeedtestTrackerPlugin.setup(site, form(url: "http://192.0.2.8:8765", token: "x")).alert).to include("ainda não tem teste")
    end
  end

  describe "ntfy" do
    let!(:integration) do
      o = Integrations::NtfyPlugin.setup(site, form(url: "http://192.0.2.9:8093", topic: "casa-teste", token: "tk_teste", priority: "high"))
      raise "não conectou: #{o.alert}" unless o.to == :index && o.alert.nil?

      site.integrations.find_by!(driver: "ntfy")
    end

    it "é canal de aviso: manda título, texto, prioridade e os botões como ações http (sem sair para a rede)" do
      sent = stub_request(:post, "http://192.0.2.9:8093").with(headers: { "Authorization" => "Bearer tk_teste" }).to_return(status: 200, body: "{}")
      n = Notification.create!(kind: "aviso", title: "Portão aberto", body: "Há 10 min",
                               data: { "url" => "/alertas", "actions" => [ { "id" => "fechar", "title" => "Fechar" } ] })
      expect(Notifier::Channels::Messenger.choices(site).map(&:first)).to include("messenger:#{integration.id}")
      ENV["APP_HOST"] = "casa.teste"
      Notifier::Channels::Messenger.deliver("messenger:#{integration.id}", [ n ])
      body = nil
      expect(sent.with { |r| body = JSON.parse(r.body) }).to have_been_requested
      expect(body).to include("topic" => "casa-teste", "title" => "Portão aberto", "message" => "Há 10 min", "priority" => 4, "click" => "https://casa.teste/alertas")
      expect(body["actions"].first).to include("action" => "http", "label" => "Fechar", "url" => "https://casa.teste/mensageiros/#{integration.id}", "body" => "#{n.id}:0")
      expect(body["actions"].first["headers"]["X-MA-Token"]).to eq(integration.secrets["webhook_secret"])
    ensure
      ENV.delete("APP_HOST")
    end

    it "resposta do botão só com o segredo; tópico inválido é recusado" do
      user = create(:user, tenant: tenant, role: "owner")
      n = Notification.create!(kind: "aviso", title: "Portão", data: { "actions" => [ { "id" => "fechar", "title" => "Fechar" } ] })
      req = ->(token, body) { ActionDispatch::Request.new(Rack::MockRequest.env_for("/mensageiros/x", method: "POST", input: body, "HTTP_X_MA_TOKEN" => token)) }
      expect(Integrations::NtfyPlugin.webhook(integration, req.("errado", "#{n.id}:0")).first).to eq(403)
      expect(Integrations::NtfyPlugin.webhook(integration, req.(integration.secrets["webhook_secret"], "#{n.id}:0")).first).to eq(200)
      expect(n.reload.response).to include("action" => "fechar", "user_id" => user.id)
      expect(Integrations::NtfyPlugin.setup(site, form(topic: "tem espaço")).alert).to include("Tópico inválido")
    end
  end

  describe "Double Take" do
    it "rosto reconhecido liga a presença da pessoa (Face), anota a câmera e dispara o evento" do
      i = add(Integrations::DoubleTakePlugin, names: "Herlon\nMaria", hold_s: 120)
      expect(i.devices.count).to eq(2)
      seen = i.devices.find_by!(name: "Rosto: Herlon").points.find_by!("address->>'field' = 'seen'")
      expect(seen.address).to include("hold_s" => 120, "tracker" => "face")
      expect(Mqtt::Listener::DISCOVERY).to include("DoubleTake")
      expect(DoubleTake.topics).to eq([ "double-take/matches/+" ])
      expect(DoubleTake.handles?("double-take/matches/herlon")).to be(true)
      fired = []
      allow(Automations::Triggers).to receive(:event).and_wrap_original { |m, *a, **k| fired << a[1..2]; m.call(*a, **k) }
      DoubleTake.handle("double-take/matches/herlon", { camera: "portao", match: { name: "herlon", confidence: 91.5 } }.to_json)
      expect(seen.reload.value).to be(true)
      expect(i.devices.find_by!(name: "Rosto: Herlon").points.find_by!("address->>'field' = 'camera'").value).to eq("portao")
      expect(fired).to eq([ [ "face_recognized", { "name" => "herlon", "camera" => "portao", "confidence" => 91.5, "zones" => [] } ] ])
      DoubleTake.handle("double-take/matches/unknown", "{}")
      DoubleTake.handle("double-take/matches/maria", "não é json")

      zones = [ HelperTypes::Zone.home(site) ]
      expect(People.tracker_for(seen)).to eq(People::Trackers::Face)
      expect(People::Trackers::Face.zone(seen, nil, zones)).to eq("Casa")
      seen.report!(false)
      expect(People::Trackers::Face.zone(seen, nil, zones)).to be_nil
    end
  end

  describe "ESPresense" do
    before { Espresense.reset! }

    it "cômodo da placa mais perto (ou do Companion), ocupação por cômodo e o rastreador Room" do
      i = add(Integrations::EspresensePlugin, devices: "irk:abc = Celular da Ana\nlixo inválido com espaço", rooms: "Sala\nQuarto", max_distance: 5, timeout_s: 30)
      phone = i.devices.find_by!(name: "Celular da Ana")
      room = phone.points.find_by!("address->>'field' = 'room'")
      sala = i.devices.find_by!("address->>'room' = 'sala'").points.first
      quarto = i.devices.find_by!("address->>'room' = 'quarto'").points.first
      expect(Espresense.topics).to contain_exactly("espresense/devices/+/+", "espresense/companion/+")
      expect(Espresense.handles?("espresense/devices/irk:abc/sala")).to be(true)

      Espresense.handle("espresense/devices/irk:abc/sala", { distance: 1.2 }.to_json)
      Espresense.handle("espresense/devices/irk:abc/quarto", { distance: 3.4 }.to_json)
      Espresense.handle("espresense/devices/outro/sala", { distance: 0.5 }.to_json) # não listado: ignorado
      expect([ room.reload.value, sala.reload.value, quarto.reload.value ]).to eq([ "sala", true, false ])

      Espresense.handle("espresense/devices/irk:abc/quarto", { distance: 0.4 }.to_json)
      expect([ room.reload.value, sala.reload.value, quarto.reload.value ]).to eq([ "quarto", false, true ])
      Espresense.handle("espresense/companion/irk:abc", "Sala")
      expect(room.reload.value).to eq("sala")

      zones = [ HelperTypes::Zone.home(site) ]
      expect(People.tracker_for(room)).to eq(People::Trackers::Room)
      expect(People::Trackers::Room.zone(room, nil, zones)).to eq("Casa")
      Espresense.handle("espresense/companion/irk:abc", "not_home")
      expect(People::Trackers::Room.zone(room.reload, nil, zones)).to be_nil

      Espresense.reset!
      Integrations::EspresensePlugin.poll(phone.reload) # leitura periódica: sumiu = fora de alcance
      expect(room.reload.value).to eq("not_home")
      expect(Integrations::EspresensePlugin.setup(site, form(devices: "  ")).alert).to be_present
    end
  end

  describe "OwnTracks" do
    let(:last) { [ { "username" => "ana", "device" => "pixel", "lat" => -15.80, "lon" => -47.90, "acc" => 10, "tst" => Time.current.to_i, "batt" => 77 } ] }

    it "a posição vira a zona no ponto Presença; a coordenada fica só nos atributos e some no prazo" do
      HelperTypes::Zone.home(site)
      stub = stub_request(:get, "http://192.0.2.3:8083/api/0/last").to_return { json(last) }
      i = add(Integrations::OwntracksPlugin, url: "http://192.0.2.3:8083", location_keep_h: 2)
      d = i.devices.first
      Integrations::OwntracksPlugin.poll(d.reload)
      p = d.points.reload.index_by { |x| x.address["field"] }
      expect([ d.name, p["location"].name, p["location"].value, p["battery"].value ]).to eq([ "ana · pixel", "Presença", "Casa", 77.0 ])
      expect(p["location"].attrs).to include("zone" => "Casa", "latitude" => -15.8, "longitude" => -47.9)
      expect(People.tracker_for(p["location"])).to eq(People::Trackers::Gps)
      expect(Reading.where(point_id: p["location"].id).pluck(:value_text)).to all(eq("Casa"))

      last.first.merge!("lat" => -10.0, "lon" => -40.0, "tst" => 3.hours.ago.to_i)
      Integrations::OwntracksPlugin.poll(d.reload)
      expect(p["location"].reload.value).to eq("Fora")
      Integrations::OwntracksPlugin.tick(Time.current)
      expect(p["location"].reload.attrs.keys).to contain_exactly("zone", "at")
      expect(stub).to have_been_requested.at_least_times(3)
    end

    it "sem guardar coordenada (0 h) só a zona fica" do
      stub_request(:get, "http://192.0.2.4:8083/api/0/last").to_return(json(last))
      i = add(Integrations::OwntracksPlugin, url: "http://192.0.2.4:8083", location_keep_h: 0)
      Integrations::OwntracksPlugin.poll(i.devices.first)
      expect(i.devices.first.points.find_by!("address->>'field' = 'location'").attrs.keys).to contain_exactly("zone", "at")
    end
  end

  describe "InfluxDB e Grafana" do
    it "InfluxDB exporta as leituras em lote pelo relógio (nenhuma tarefa por leitura) e o cursor anda" do
      stub_request(:post, %r{/api/v2/write}).to_return(status: 204, body: "")
      Integrations::InfluxdbPlugin.setup(site, form(url: "http://192.0.2.40:8086", org: "casa", bucket: "minha_automacao", token: "tok"))
      i = site.integrations.find_by!(driver: "influxdb")
      expect(StateReport.reporters).not_to include(Integrations::InfluxdbPlugin)
      device = site.devices.create!(name: "Teste Medidor", driver: "virtual")
      power = device.points.create!(site: site, name: "Teste Potência", key: "teste.potencia", capability: "measure", unit: "W")
      relay = device.points.create!(site: site, name: "Teste Relé", key: "teste.rele", capability: "onoff")
      travel_to(1.minute.from_now) do
        expect { power.report!(42.5) }.not_to have_enqueued_job(StateReportJob)
        relay.report!(true)
      end
      travel_to(2.minutes.from_now) do
        expect(Integrations::InfluxdbPlugin.export!(i.reload)).to eq(2)
        expect(Integrations::InfluxdbPlugin.export!(i.reload)).to eq(0)
      end
      expect(a_request(:post, "http://192.0.2.40:8086/api/v2/write?bucket=minha_automacao&org=casa&precision=s")
               .with(body: /\AW,entity_id=teste.potencia,domain=measure value=42.5 \d+\nstate,entity_id=teste.rele,domain=onoff value=1i \d+\z/)).to have_been_made
      stub_request(:post, %r{/api/v2/write}).to_return(status: 500)
      travel_to(3.minutes.from_now) { power.report!(1.0) }
      travel_to(4.minutes.from_now) { Integrations::InfluxdbPlugin.tick(Time.current) }
      expect(i.reload.status).to eq("error")
    end

    it "Grafana: fonte de dados do InfluxDB e o painel inicial pela API (409 = atualiza)" do
      auth = { basic_auth: %w[admin senha-teste] }
      stub_request(:post, "http://192.0.2.50:3002/api/datasources").with(**auth).to_return(status: 409, body: "{}")
      put = stub_request(:put, "http://192.0.2.50:3002/api/datasources/uid/minha-automacao").with(**auth).to_return(json({}))
      dash = stub_request(:post, "http://192.0.2.50:3002/api/dashboards/db").with(**auth).to_return(json({}))
      o = Integrations::GrafanaPlugin.setup(site, form(url: "http://192.0.2.50:3002", password: "senha-teste", token: "tok-influx"))
      expect([ o.to, o.alert ]).to eq([ :index, nil ])
      expect(put.with { |r| JSON.parse(r.body).dig("secureJsonData", "token") == "tok-influx" && JSON.parse(r.body)["url"] == "http://ma-app-influxdb:8086" }).to have_been_requested
      expect(dash.with { |r| JSON.parse(r.body).dig("dashboard", "panels").size == 4 && r.body.include?("minha_automacao") }).to have_been_requested
    end
  end

  describe "voz Wyoming como provedor de IA" do
    def fake_wyoming
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        loop do
          sock = server.accept
          c = Wyoming::Connection.new(sock, 5)
          type, data = c.read
          if type == "transcribe"
            loop { t, = c.read; break if t.nil? || t == "audio-stop" }
            c.write("transcript", { "text" => "acender a luz (#{data['language']})" })
          else
            c.write("audio-start", { "rate" => 22_050, "width" => 2, "channels" => 1 })
            c.write("audio-chunk", {}, "\x01\x00".b * 100)
            c.write("audio-stop")
          end
          sock.close
        end
      rescue IOError, Errno::EBADF
        nil
      end
      yield server.addr[1]
    ensure
      thread&.kill
      server&.close
    end

    it "transcreve e fala pelo Ai::Audio, com tcp:// na conta e as duas portas" do
      fake_wyoming do |port|
        AiAccount.create!(provider: "wyoming", base_url: "tcp://127.0.0.1:#{port}?tts=#{port}", enabled: true)
        wav = Wyoming.wav(([ 3000, -3000 ].pack("s<s<") * 800).b, 16_000, 2, 1)
        res = Ai::Audio.transcribe(tenant: tenant, audio: wav, media_type: "audio/wav", language: "pt-BR")
        expect([ res.data, res.provider ]).to eq([ "acender a luz (pt)", "wyoming" ])
        voice = Ai::Audio.speak(tenant: tenant, text: "Olá")
        expect([ voice.data[:media_type], voice.data[:data][0, 4] ]).to eq([ "audio/wav", "RIFF" ])
        expect { Ai::Audio.transcribe(tenant: tenant, audio: "mp3", media_type: "audio/mpeg") }.to raise_error(Ai::Client::Error, /WAV/)
      end
      expect(AiAccount.new(provider: "wyoming", base_url: "ftp://x")).not_to be_valid
      expect(Ai::Providers::Wyoming.new(base_url: "tcp://casa").send(:port, :tts)).to eq(10_200)
    end

    it "Ollama: preparar baixa o modelo da conta pelo /api/pull" do
      tenant.update!(http_allow_text: "192.0.2.60")
      pull = stub_request(:post, "http://192.0.2.60:11434/api/pull").with(body: { model: "qwen2.5:1.5b", stream: false }.to_json).to_return(json("status" => "success"))
      a = AiAccount.create!(provider: "ollama", base_url: "http://192.0.2.60:11434", model: "qwen2.5:1.5b")
      AiPrepareJob.perform_now(a.id)
      expect(pull).to have_been_requested
      expect(a.reload.last_ok_at).to be_present
      stub_request(:post, "http://192.0.2.60:11434/api/pull").to_return(status: 500, body: "{}")
      AiPrepareJob.perform_now(a.id)
      expect(a.reload.last_error).to include("não baixou")
    end
  end
end
