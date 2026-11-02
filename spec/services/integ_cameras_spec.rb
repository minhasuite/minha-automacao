require "rails_helper"

# integ: câmeras com IA (Frigate, Reolink, UniFi Protect) virando a
# capacidade genérica `detection`, o gatilho "Câmera detectou" e o aviso com
# quadro. Respostas gravadas (WebMock), nada de rede ou conta real.
RSpec.describe "Câmeras com IA (integ)" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:jpeg) { "\xFF\xD8\xFF\xE0fake".b }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def json(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  def form(h) = ActionController::Parameters.new(h)

  def adopt(outcome)
    expect(outcome.alert).to be_nil
    Integrations.adopt!(outcome.integration, outcome.integration.found.to_h { |e| [ e["id"], "" ] })
  end

  describe "capacidade e gatilho genéricos" do
    let(:device) { create(:device, site: site, name: "Câmera falsa", driver: "virtual") }
    let(:det) { create(:point, device: device, site: site, name: "Detecção", capability: "detection") }

    it "nasce só leitura, mostra o texto e a mesma detecção repetida dispara de novo" do
      expect(det).to have_attributes(data_type: "json", writable: false)
      v = Detections.value(label: "car", score: 91.4, zones: %w[garagem])
      expect(v).to include("kind" => "vehicle", "label" => "car", "score" => 91, "zones" => [ "garagem" ])
      det.report!(v)
      expect(ApplicationController.helpers.point_value_text(det)).to eq("Veículo · garagem · 91%")
      expect { det.report!(v) }.to change { det.reload.changed_at } # conta a cada aviso, como o evento
    end

    it "gatilho por tipo, zona e confiança; avisar leva o quadro do plugin da câmera (plugin falso)" do
      fake = Class.new(Integrations::Plugin) do
        describe key: "camera_falsa", title: "Câmera falsa", icon: "video-camera", description: "teste", driver: "camera_falsa"
        def self.snapshot(_point) = "\xFF\xD8quadro".b
      end
      stub_const("Integrations::FakeCamPlugin", fake)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[FakeCamPlugin])
      device.update!(driver: "camera_falsa")
      a = Automation.create!(site: site, name: "Teste pessoa na garagem", mode: "single")
      a.publish!({ "triggers" => [ { "type" => "detection", "point" => det.id, "kind" => "person", "zone" => "Garagem", "min_score" => 70 } ],
                   "actions" => [ { "type" => "notify", "title" => "Pessoa na garagem", "camera" => det.id, "channels" => [ "in_app" ] } ] })
      a.update!(enabled: true)
      det.report!(Detections.value(label: "dog", score: 99, zones: %w[garagem]))
      det.report!(Detections.value(label: "person", score: 50, zones: %w[garagem]))
      det.report!(Detections.value(label: "person", score: 88, zones: %w[rua]))
      expect(a.runs.count).to eq(0)
      det.report!(Detections.value(label: "person", score: 88, zones: %w[garagem]))
      expect(a.runs.count).to eq(1)
      n = Notification.order(:created_at).last
      expect(n.title).to eq("Pessoa na garagem")
      expect(n.image.download).to start_with("\xFF\xD8quadro".b)
      expect(Automations::TriggerTypes::DetectionTrigger.title("kind" => "vehicle")).to eq("Câmera detectou veículo")
    end
  end

  describe "Frigate" do
    let(:base) { "http://10.0.0.20:5000" }
    let(:config) do
      { "cameras" => { "garagem" => { "enabled" => true, "objects" => { "track" => %w[person car] }, "zones" => { "entrada" => {} } },
                       "quintal" => { "objects" => { "track" => %w[person dog] } }, "desligada" => { "enabled" => false } } }
    end
    let(:event) do
      { "id" => "1730500000.123-abc", "camera" => "garagem", "label" => "person", "top_score" => 0.87, "zones" => [ "entrada" ],
        "start_time" => Time.current.to_f - 5, "has_clip" => true, "has_snapshot" => true }
    end

    before do
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS | %w[FrigatePlugin])
      stub_request(:get, "#{base}/api/config").to_return(json(config))
    end

    def setup = adopt(Integrations::FrigatePlugin.setup(site, form(url: "10.0.0.20:5000")))
    def garage = site.devices.find_by!(external_id: "frigate:garagem")

    it "câmeras viram aparelhos com detecção e sensores por objeto; leitura acha a detecção nova e o que vê agora" do
      expect(setup).to eq(2)
      expect(garage.points.pluck(:name, :capability)).to contain_exactly([ "Detecção", "detection" ], [ "Pessoa na câmera", "motion" ], [ "Veículo na câmera", "motion" ])
      expect(garage.address).to include("camera" => "garagem", "zones" => [ "entrada" ])

      stub_request(:get, "#{base}/api/events?camera=garagem&limit=1").to_return(json([ event ]))
      stub_request(:get, "#{base}/api/events?camera=garagem&in_progress=1&limit=50").to_return(json([ event ]))
      Frigate.poll(garage)
      det = garage.points.find_by!(capability: "detection")
      expect(det.value).to include("kind" => "person", "score" => 87, "zones" => [ "entrada" ], "id" => event["id"], "clip" => "#{base}/api/events/#{event['id']}/clip.mp4")
      expect(garage.points.find_by!(name: "Pessoa na câmera").value).to be true
      expect(garage.points.find_by!(name: "Veículo na câmera").value).to be false
      expect { Frigate.poll(garage) }.not_to(change { det.reload.changed_at }) # mesma detecção não conta duas vezes

      stub_request(:get, "#{base}/api/events/#{event['id']}/snapshot.jpg?bbox=1").to_return(status: 200, body: jpeg)
      expect(Integrations.snapshot(det)).to eq(jpeg)
    end

    it "detecção velha (primeira leitura) não dispara; fora do ar = indisponível" do
      setup
      stub_request(:get, "#{base}/api/events?camera=garagem&limit=1").to_return(json([ event.merge("start_time" => 1.hour.ago.to_f) ]))
      stub_request(:get, "#{base}/api/events?camera=garagem&in_progress=1&limit=50").to_return(json([]))
      Frigate.poll(garage)
      expect(garage.points.find_by!(capability: "detection").value).to be_nil
      stub_request(:get, "#{base}/api/events?camera=garagem&limit=1").to_raise(Errno::ECONNREFUSED)
      expect { Frigate.poll(garage) }.to raise_error(Integrations::Error, /Sem conexão/)
      Frigate.unavailable!(garage)
      expect(garage.points.reload.map(&:quality).uniq).to eq([ "unavailable" ])
    end

    it "MQTT: evento novo e contagem por objeto chegam na hora (fora do inquilino, como no ouvinte)" do
      setup
      expect(Mqtt::Listener.discoverers).to include(Frigate)
      ActsAsTenant.without_tenant do
        expect(Frigate.topics).to eq(%w[frigate/events frigate/+/+])
        expect(Frigate.handles?("frigate/garagem/person")).to be true
        Frigate.handle("frigate/events", { "type" => "new", "after" => event.merge("entered_zones" => [ "entrada" ]) }.to_json)
        Frigate.handle("frigate/garagem/car", "2")
        Frigate.handle("frigate/garagem/car/snapshot", "binário") # outro tópico: ignora
      end
      expect(garage.points.find_by!(capability: "detection").value).to include("kind" => "person", "zones" => [ "entrada" ])
      expect(garage.points.find_by!(name: "Veículo na câmera").value).to be true
    end
  end

  describe "Reolink" do
    let(:base) { "http://10.0.0.30" }

    def api(cmd, value) = stub_request(:post, %r{\A#{base}/api.cgi\?cmd=#{cmd}&token=tk1}).to_return(json([ { "cmd" => cmd, "code" => 0, "value" => value } ]))

    before do
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS | %w[ReolinkPlugin])
      stub_request(:post, "#{base}/api.cgi?cmd=Login").with { |r| r.body.include?('"userName":"admin","password":"s3nha"') }
                                                     .to_return(json([ { "cmd" => "Login", "code" => 0, "value" => { "Token" => { "name" => "tk1", "leaseTime" => 3600 } } } ]))
      api("GetDevInfo", { "DevInfo" => { "name" => "Portão", "model" => "RLC-810A", "serial" => "00000000000001", "channelNum" => 1 } })
      api("GetMdState", { "state" => 1 })
      Reolink.tokens.clear
    end

    it "lê o canal com os tipos de IA do aparelho e acende a detecção quando um tipo liga" do
      off = { "people" => { "alarm_state" => 0, "support" => 1 }, "vehicle" => { "alarm_state" => 0, "support" => 1 }, "dog_cat" => { "alarm_state" => 0, "support" => 0 } }
      api("GetAiState", off)
      adopt(Integrations::ReolinkPlugin.setup(site, form(host: "10.0.0.30", username: "admin", password: "s3nha")))
      device = site.devices.find_by!(driver: "reolink")
      expect(device.integration.settings).to include("username" => "admin")
      expect(device.integration.settings.to_json).not_to include("s3nha")
      expect(device.points.pluck(:name)).to contain_exactly("Detecção", "Movimento", "Pessoa na câmera", "Veículo na câmera")

      api("GetAiState", off.merge("vehicle" => { "alarm_state" => 1, "support" => 1 }))
      Reolink.poll(device)
      expect(device.points.find_by!(name: "Movimento").value).to be true
      expect(device.points.find_by!(name: "Veículo na câmera").value).to be true
      expect(device.points.find_by!(capability: "detection").value).to include("kind" => "vehicle")

      stub_request(:get, %r{\A#{base}/cgi-bin/api.cgi\?}).with(query: hash_including("cmd" => "Snap", "channel" => "0", "token" => "tk1")).to_return(status: 200, body: jpeg)
      expect(Integrations.snapshot(device.points.find_by!(capability: "detection"))).to eq(jpeg)
    end

    it "senha errada vira erro de credencial (Reconfigurar)" do
      Reolink.tokens.clear
      stub_request(:post, "#{base}/api.cgi?cmd=Login").to_return(json([ { "cmd" => "Login", "code" => 1, "error" => { "rspCode" => -7, "detail" => "login failed" } } ]))
      o = Integrations::ReolinkPlugin.setup(site, form(host: "10.0.0.30", username: "admin", password: "errada"))
      expect(o.alert).to match(/não conferem/)
    end
  end

  describe "UniFi Protect" do
    let(:base) { "https://10.0.0.1" }
    let(:cam) { { "id" => "cam1", "mac" => "AABBCCDDEEFF", "name" => "Entrada", "marketName" => "G4 Doorbell", "isConnected" => true, "lastMotion" => 0, "featureFlags" => { "smartDetectTypes" => %w[person package] } } }

    before do
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS | %w[UnifiProtectPlugin])
      UnifiProtect.sessions.clear
      stub_request(:post, "#{base}/api/auth/login").with(body: hash_including("username" => "ma", "password" => "s3nha"))
                                                   .to_return(status: 200, body: "{}", headers: { "Set-Cookie" => "TOKEN=abc; path=/; HttpOnly", "X-CSRF-Token" => "csrf1" })
      stub_request(:get, "#{base}/proxy/protect/api/bootstrap").with(headers: { "Cookie" => "TOKEN=abc", "X-CSRF-Token" => "csrf1" }).to_return(json("cameras" => [ cam ]))
    end

    it "câmeras do console com detecção inteligente; evento novo vira detecção e o quadro vem da câmera" do
      adopt(Integrations::UnifiProtectPlugin.setup(site, form(host: "10.0.0.1", username: "ma", password: "s3nha")))
      device = site.devices.find_by!(external_id: "unifi:AABBCCDDEEFF")
      expect(device.points.pluck(:name)).to contain_exactly("Detecção", "Movimento", "Pessoa na câmera", "Encomenda na câmera")

      now = Time.current
      stub_request(:get, "#{base}/proxy/protect/api/cameras/cam1").to_return(json(cam.merge("isMotionDetected" => true)))
      stub_request(:get, %r{#{base}/proxy/protect/api/events\?}).to_return(json([ { "id" => "ev9", "camera" => "cam1", "type" => "smartDetectZone", "score" => 82,
                                                                                    "smartDetectTypes" => [ "package" ], "start" => (now.to_f * 1000).to_i - 3000, "end" => nil } ]))
      UnifiProtect.poll(device)
      expect(device.points.find_by!(capability: "detection").value).to include("kind" => "package", "score" => 82, "id" => "ev9")
      expect(device.points.find_by!(name: "Encomenda na câmera").value).to be true
      expect(device.points.find_by!(name: "Movimento").value).to be true

      stub_request(:get, "#{base}/proxy/protect/api/cameras/cam1/snapshot").to_return(status: 200, body: jpeg)
      expect(Integrations.snapshot(device.points.find_by!(capability: "detection"))).to eq(jpeg)
    end
  end
end
