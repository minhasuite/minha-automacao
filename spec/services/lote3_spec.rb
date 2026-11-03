require "rails_helper"

# Lote 3 (paridade HA): câmeras genéricas (RTSP/ONVIF, movimento por
# PullPoint), câmera Tuya pelo mapa de dados (movimento e sirene), sessão
# própria da Alexa (login, renovação, rotina) e a ação "Falar". Nada sai
# para a rede: WebMock em tudo.
RSpec.describe "Lote 3: câmeras e Alexa" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site, name: "Local") }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  def soap(body) = %(<?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2" xmlns:wsa="http://www.w3.org/2005/08/addressing"><s:Body>#{body}</s:Body></s:Envelope>)

  def build(definition)
    a = Automation.create!(site: site, name: "Teste #{SecureRandom.hex(3)}", kind: "automation", mode: "single")
    a.publish!(definition)
    a
  end

  describe "ONVIF" do
    let(:dev_url) { "http://10.0.0.20:8000/onvif/device_service" }
    let(:media) { "http://10.0.0.20:8000/onvif/media" }
    let(:events) { "http://10.0.0.20:8000/onvif/events" }
    let(:sub) { "http://10.0.0.20:8000/onvif/sub/1" }

    def stub_onvif(events_service: true)
      stub_request(:post, dev_url).with(body: /GetSystemDateAndTime/).to_return(body: soap(
        "<tt:UTCDateTime><tt:Time><tt:Hour>10</tt:Hour><tt:Minute>0</tt:Minute><tt:Second>0</tt:Second></tt:Time>" \
        "<tt:Date><tt:Year>2026</tt:Year><tt:Month>10</tt:Month><tt:Day>30</tt:Day></tt:Date></tt:UTCDateTime>"
      ))
      stub_request(:post, dev_url).with(body: /GetDeviceInformation/).to_return(body: soap("<x><tt:Manufacturer>Marca</tt:Manufacturer><tt:Model>M1</tt:Model><tt:SerialNumber>SN9</tt:SerialNumber></x>"))
      stub_request(:post, dev_url).with(body: /GetCapabilities/).to_return(body: soap(
        "<tt:Capabilities><tt:Media><tt:XAddr>#{media}</tt:XAddr></tt:Media>#{"<tt:Events><tt:XAddr>#{events}</tt:XAddr></tt:Events>" if events_service}</tt:Capabilities>"
      ))
      stub_request(:post, media).with(body: /GetProfiles/).to_return(body: soap(
        %(<r><Profiles token="p0"><tt:Name>Principal</tt:Name><tt:VideoEncoderConfiguration><tt:Resolution><tt:Width>1920</tt:Width><tt:Height>1080</tt:Height></tt:Resolution></tt:VideoEncoderConfiguration></Profiles>) +
        %(<Profiles token="p1"><tt:Name>Sub</tt:Name></Profiles></r>)
      ))
      stub_request(:post, media).with(body: /ProfileToken>p0</).to_return(body: soap("<r><MediaUri><tt:Uri>rtsp://10.0.0.20:554/live/ch0</tt:Uri></MediaUri></r>"))
      stub_request(:post, media).with(body: /ProfileToken>p1</).to_return(body: soap("<r><MediaUri><tt:Uri>rtsp://10.0.0.20:8554/live/ch1?x=1</tt:Uri></MediaUri></r>"))
    end

    def motion_message(value) = %(<wsnt:NotificationMessage><wsnt:Topic>tns1:RuleEngine/CellMotionDetector/Motion</wsnt:Topic><wsnt:Message><tt:Message><tt:Data><tt:SimpleItem Name="IsMotion" Value="#{value}"/></tt:Data></tt:Message></wsnt:Message></wsnt:NotificationMessage>)

    it "lê nome, perfis e endereços RTSP com WS-Security e cria o ponto de movimento" do
      stub_onvif
      entry = Onvif.inventory({ "host" => "10.0.0.20", "onvif_port" => 8000, "username" => "admin" }, "segredo")
      expect(entry).to include("id" => "onvif:10.0.0.20", "kind" => "go2rtc", "name" => "Marca M1", "manufacturer" => "Marca",
                               "address" => { "host" => "10.0.0.20", "port" => 554, "username" => "admin", "onvif_port" => 8000 })
      expect(entry["points"]).to eq([
        { "name" => "Principal 1920x1080", "capability" => "stream", "history" => "none", "writable" => true,
          "address" => { "path" => "/live/ch0", "profile" => "p0", "supports" => %w[record] } },
        { "name" => "Sub", "capability" => "stream", "history" => "none", "writable" => true,
          "address" => { "path" => "/live/ch1?x=1", "port" => 8554, "profile" => "p1", "supports" => %w[record] } },
        { "name" => "Movimento", "capability" => "motion", "device_class" => "motion", "address" => { "onvif" => "motion" } }
      ])
      expect(a_request(:post, dev_url).with(body: /<wsse:Username>admin<.*PasswordDigest/)).to have_been_made.at_least_once
      expect(a_request(:post, dev_url).with(body: /segredo/)).not_to have_been_made # senha só no digest
    end

    it "sem eventos não cria movimento; sem mídia ou perfil é erro; senha recusada é erro de credencial" do
      stub_onvif(events_service: false)
      expect(Onvif.inventory({ "host" => "10.0.0.20", "onvif_port" => 8000 }, nil)["points"].map { |p| p["capability"] }).to eq(%w[stream stream])

      stub_request(:post, dev_url).with(body: /GetCapabilities/).to_return(body: soap("<tt:Capabilities/>"))
      expect { Onvif.inventory({ "host" => "10.0.0.20", "onvif_port" => 8000 }, nil) }.to raise_error(Onvif::Error, /Media/)

      stub_request(:post, dev_url).with(body: /GetDeviceInformation/).to_return(status: 400, body: soap("<s:Fault><s:Reason><s:Text>Sender not Authorized</s:Text></s:Reason></s:Fault>"))
      expect { Onvif.inventory({ "host" => "10.0.0.20", "onvif_port" => 8000 }, "x") }.to raise_error(Integrations::AuthError)
      stub_request(:post, dev_url).with(body: /GetDeviceInformation/).to_raise(Errno::ECONNREFUSED)
      expect { Onvif::Client.new(host: "10.0.0.20", port: 8000).info }.to raise_error(Onvif::Error, /Sem conexão/)
      stub_request(:post, dev_url).with(body: /GetDeviceInformation/).to_return(body: "<<<")
      expect { Onvif::Client.new(host: "10.0.0.20", port: 8000).info }.to raise_error(Onvif::Error)
    end

    it "o ouvinte assina, passa o movimento para o ponto e marca indisponível quando cai" do
      stub_onvif
      device = create(:device, site: site, name: "Cam", driver: "go2rtc", address: { "host" => "10.0.0.20", "onvif_port" => 8000, "username" => "admin" }, credential: "segredo")
      motion = create(:point, device: device, site: site, name: "Movimento", capability: "motion", address: { "onvif" => "motion" })
      expect(Onvif::Listener.motion_points.pluck(:id)).to eq([ motion.id ])
      stub_request(:post, events).with(body: /CreatePullPointSubscription/).to_return(body: soap(
        "<r><wsnt:SubscriptionReference><wsa:Address>#{sub}</wsa:Address><wsa:ReferenceParameters><x:Id xmlns:x=\"urn:x\">7</x:Id></wsa:ReferenceParameters></wsnt:SubscriptionReference></r>"
      ))
      pull = stub_request(:post, sub).with(body: /PullMessages.*/m).to_return(body: soap("<r>#{motion_message('true')}</r>")).then.to_return(body: soap("<r>#{motion_message('false')}</r>"))
      unsub = stub_request(:post, sub).with(body: /Unsubscribe/).to_return(body: soap("<r/>"))

      expect(Onvif::Listener.run_once(device.id, rounds: 1)).to be true
      expect(motion.reload).to have_attributes(value: true, quality: "good")
      expect(a_request(:post, sub).with(body: %r{<wsa:To>#{sub}</wsa:To>.*urn:x}m)).to have_been_made.at_least_once
      Onvif::Listener.run_once(device.id, rounds: 1)
      expect(motion.reload.value).to be false
      expect(pull).to have_been_requested.twice
      expect(unsub).to have_been_requested.twice

      stub_request(:post, events).with(body: /CreatePullPointSubscription/).to_raise(Errno::EHOSTUNREACH)
      expect(Onvif::Listener.run_once(device.id, rounds: 1)).to be false
      expect(motion.reload.quality).to eq("unavailable")
      expect(Onvif::Listener.run_once(SecureRandom.uuid)).to be true # aparelho apagado: nada a fazer
    end
  end

  describe "plugin Câmera RTSP / ONVIF" do
    let(:plugin) { Integrations::CameraPlugin }

    it "RTSP: tira usuário e senha da URL, guarda a senha cifrada e adota um aparelho go2rtc" do
      outcome = plugin.setup(site, ActionController::Parameters.new(mode: "rtsp", name: "Garagem", url: "rtsps://admin:s3nh%40x@10.0.0.30:322/stream2?canal=1"))
      expect(outcome.to).to eq(:found)
      integration = outcome.integration
      expect(integration.settings).to include("mode" => "rtsp", "scheme" => "rtsps", "host" => "10.0.0.30", "port" => 322, "path" => "/stream2?canal=1", "username" => "admin")
      expect(integration.settings.to_json).not_to include("s3nh")
      expect(integration.secrets).to eq("password" => "s3nh@x")
      expect(Integrations.adopt!(integration, integration.found.first["id"] => "")).to eq(1)
      cam = site.devices.find_by!(name: "Garagem")
      expect([ cam.driver, cam.credential, cam.integration ]).to eq([ "go2rtc", "s3nh@x", integration ])
      expect(Drivers::Go2rtc.source(cam.points.sole)).to eq("rtsps://admin:s3nh%40x@10.0.0.30:322/stream2?canal=1")

      # Reconfigurar sem URL nova mantém o endereço e troca só a senha.
      expect(plugin.login(integration, ActionController::Parameters.new(password: "nova")).to).to eq(:found)
      expect(integration.reload.secrets["password"]).to eq("nova")
      expect(integration.settings["path"]).to eq("/stream2?canal=1")
    end

    it "valida o endereço e o modo ONVIF usa o inventário ONVIF" do
      expect(plugin.setup(site, ActionController::Parameters.new(mode: "rtsp", url: "http://x/y"))).to have_attributes(to: :form, alert: /RTSP/)
      expect(plugin.setup(site, ActionController::Parameters.new(mode: "onvif"))).to have_attributes(to: :form, alert: /IP/)
      expect(plugin.parse("rtsp://[")).to be_nil

      allow(Onvif).to receive(:inventory).and_return({ "id" => "onvif:SN", "kind" => "go2rtc", "name" => "Cam", "points" => [] })
      o = plugin.setup(site, ActionController::Parameters.new(mode: "onvif", host: "10.0.0.20", onvif_port: "8000", username: "u", password: "p"))
      expect(o.integration.settings).to include("mode" => "onvif", "host" => "10.0.0.20", "onvif_port" => 8000)
      expect(Onvif).to have_received(:inventory).with(hash_including("host" => "10.0.0.20"), "p")
      allow(Onvif).to receive(:inventory).and_raise(Onvif::Error, "Sem conexão com 10.0.0.20")
      expect(plugin.login(o.integration, ActionController::Parameters.new)).to have_attributes(to: :found, alert: /Sem conexão/)
    end
  end

  describe "câmera Tuya pelo mapa de dados" do
    let(:relations) do
      [ { "statusCode" => "siren_switch", "dpId" => 159, "valueType" => "Boolean" },
        { "statusCode" => "motion_switch", "dpId" => 134, "valueType" => "Boolean" },
        { "statusCode" => "initiative_message", "dpId" => 212, "valueType" => "Raw" } ]
    end
    let(:specs) { Tuya::Cloud.points("Câmera", relations, %w[siren_switch motion_switch]) }
    let(:device) do
      d = create(:device, site: site, name: "Câmera", driver: "tuya_local")
      specs.each { |s| d.points.create!(s.merge("site" => site)) }
      d
    end

    def msg(cmd) = Base64.strict_encode64({ cmd: cmd, type: "image" }.to_json)

    it "sirene é um liga/desliga crítico e o movimento vem do dp empurrado, com retorno sozinho a falso" do
      expect(specs).to include(hash_including("name" => "Sirene", "capability" => "onoff", "risk" => "critical"),
                               hash_including("name" => "Detecção de movimento", "capability" => "onoff"))
      motion_spec = specs.find { |s| s["capability"] == "motion" }
      expect(motion_spec["address"]).to eq("dps" => "212", "code" => "initiative_message", "decode" => "base64_json", "field" => "cmd", "match" => "ipc_motion", "hold_s" => 30, "push_only" => true)

      motion = device.points.find_by!(capability: "motion")
      Drivers::TuyaLocal.report(device, { "212" => msg("ipc_motion") }) # estado completo repete a última: não conta
      expect(motion.reload.value).to be_nil
      expect { Drivers::TuyaLocal.report(device, { "212" => msg("ipc_motion") }, push: true) }.to have_enqueued_job(PointHoldJob)
      expect(motion.reload.value).to be true
      Drivers::TuyaLocal.report(device, { "212" => msg("ipc_bang") }, push: true) # outro aviso da câmera: não mexe
      expect(motion.reload.value).to be true

      stamp = motion.reported_at.iso8601(6)
      PointHoldJob.perform_now(motion.id, (motion.reported_at - 1).iso8601(6)) # job velho
      expect(motion.reload.value).to be true
      PointHoldJob.perform_now(motion.id, stamp)
      expect(motion.reload.value).to be false
      expect(Points::Decode.call({ "decode" => "base64_json", "field" => "cmd", "match" => "x" }, "não é base64")).to be_nil
      expect(Points::Decode.call({ "decode" => "json", "field" => "a.b" }, '{"a":{"b":3}}')).to eq(3)
    end
  end

  describe "Alexa: sessão própria" do
    let(:integration) { Integration.create!(site: site, driver: "alexa", name: "Alexa", status: "pending", settings: { "domain" => "amazon.com.br" }) }
    let(:register_ok) do
      { "response" => { "success" => { "tokens" => { "bearer" => { "refresh_token" => "Atnr|R1", "access_token" => "Atna|A" },
                                                      "website_cookies" => [ { "Name" => "session-id", "Value" => "S1" }, { "Name" => "at-acbbr", "Value" => "\"AT\"" } ] },
                                       "extensions" => { "customer_info" => { "given_name" => "Herlon" } } } } }
    end

    def stub_csrf = stub_request(:get, "https://alexa.amazon.com.br/api/language").to_return(headers: { "Set-Cookie" => "csrf=777; Path=/" })

    it "gera o link de login com PKCE e reaproveita o pedido pendente" do
      url = Alexa::Auth.start!(integration)
      q = URI.decode_www_form(URI(url).query).to_h
      s = integration.reload.secrets
      expect(url).to start_with("https://www.amazon.com.br/ap/signin?")
      expect(q).to include("openid.assoc_handle" => "amzn_dp_project_dee_ios_br", "openid.oa2.code_challenge_method" => "S256",
                           "openid.oa2.client_id" => "device:#{"#{s['serial']}#A2IVLV5VM2W81".unpack1('H*')}",
                           "openid.return_to" => "https://www.amazon.com.br/ap/maplanding")
      expect(q["openid.oa2.code_challenge"]).to eq(Base64.urlsafe_encode64(Digest::SHA256.digest(s["verifier"]), padding: false))
      expect(Alexa::Auth.start!(integration)).to eq(url)
      expect(Alexa::Auth.login_url("amazon.com", "AB", "v")).to include("assoc_handle=amzn_dp_project_dee_ios&")
    end

    it "troca o código pelo registro, guarda cookies + csrf + refresh token e renova depois" do
      Alexa::Auth.start!(integration)
      verifier = integration.reload.secrets["verifier"]
      register = stub_request(:post, "https://api.amazon.com/auth/register")
                 .with(body: hash_including("auth_data" => hash_including("authorization_code" => "ANcode123", "code_verifier" => verifier)))
                 .to_return(body: register_ok.to_json)
      stub_csrf
      Alexa::Auth.finish!(integration, "https://www.amazon.com.br/ap/maplanding?openid.oa2.authorization_code=ANcode123&openid.mode=id_res")
      expect(register).to have_been_requested
      s = integration.reload.secrets
      expect(s).to include("cookies" => { "session-id" => "S1", "at-acbbr" => "AT", "csrf" => "777" }, "refresh_token" => "Atnr|R1")
      expect(s).not_to have_key("verifier")
      expect(integration.settings).to include("account" => "Herlon", "host" => "alexa.amazon.com.br", "login" => "app")
      expect(Alexa::Auth.cookies(integration)).to eq(s["cookies"])
      expect(Integration.connection.select_value("select credentials from integrations where id = '#{integration.id}'")).not_to include("Atnr")

      exchange = stub_request(:post, "https://www.amazon.com.br/ap/exchangetoken/cookies")
                 .with(body: hash_including("source_token" => "Atnr|R1", "requested_token_type" => "auth_cookies"), headers: { "x-amzn-identity-auth-domain" => "api.amazon.com.br" })
                 .to_return(body: { "response" => { "tokens" => { "cookies" => { ".amazon.com.br" => [ { "Name" => "session-id", "Value" => "S2" } ] } } } }.to_json)
      expect(Alexa::Auth.refresh!(integration)).to eq("session-id" => "S2", "csrf" => "777")
      expect(exchange).to have_been_requested

      stub_request(:post, "https://www.amazon.com.br/ap/exchangetoken/cookies").to_return(body: { "response" => { "error" => {} } }.to_json)
      expect { Alexa::Auth.refresh!(integration) }.to raise_error(Integrations::AuthError)
    end

    it "erros do login: sem pedido, sem código, recusado pela Amazon, fora do ar" do
      expect { Alexa::Auth.finish!(integration, "x") }.to raise_error(Alexa::Auth::Error, /expirou/)
      Alexa::Auth.start!(integration)
      expect { Alexa::Auth.finish!(integration, "https://www.amazon.com.br/ap/maplanding?x=1") }.to raise_error(Alexa::Auth::Error, /código/)
      stub_request(:post, "https://api.amazon.com/auth/register").to_return(body: { "response" => { "error" => { "code" => "InvalidValue" } } }.to_json)
      expect { Alexa::Auth.finish!(integration, "ANcodigoSolto123") }.to raise_error(Integrations::AuthError, /InvalidValue/)
      stub_request(:post, "https://api.amazon.com/auth/register").to_raise(SocketError)
      expect { Alexa::Auth.finish!(integration, "ANcodigoSolto123") }.to raise_error(Alexa::Auth::Error, /Sem conexão/)
      stub_request(:post, "https://api.amazon.com/auth/register").to_return(body: "<html>")
      expect { Alexa::Auth.finish!(integration, "ANcodigoSolto123") }.to raise_error(Alexa::Auth::Error, /ilegível/)
      expect { Alexa::Auth.refresh!(integration) }.to raise_error(Integrations::AuthError, /entre de novo/)
    end

    it "o cliente renova a sessão recusada uma vez e repete; roda rotina pelo nome ou pela frase" do
      integration.update!(credentials: { "cookies" => { "csrf" => "C1" }, "refresh_token" => "R" }.to_json, settings: integration.settings.merge("host" => "alexa.amazon.com.br"))
      allow(Alexa::Auth).to receive(:refresh!).and_return("csrf" => "C2")
      stub_request(:get, "https://alexa.amazon.com.br/api/devices-v2/device?cached=true").with(headers: { "Cookie" => "csrf=C1" }).to_return(status: 401)
      stub_request(:get, "https://alexa.amazon.com.br/api/devices-v2/device?cached=true").with(headers: { "Cookie" => "csrf=C2" }).to_return(body: { devices: [] }.to_json)
      expect(Drivers::Alexa.client_for(integration).devices).to eq([])
      expect(Alexa::Auth).to have_received(:refresh!).once

      routines = [ { "automationId" => "amzn1.r.1", "name" => "Boa noite", "sequence" => { "startNode" => { "deviceSerialNumber" => "ALEXA_CURRENT_DSN" } } },
                   { "automationId" => "amzn1.r.2", "name" => nil, "triggers" => [ { "payload" => { "utterance" => "hora do filme" } } ], "sequence" => {} } ]
      stub_request(:get, "https://alexa.amazon.com.br/api/behaviors/v2/automations?limit=2000").to_return(body: routines.to_json)
      preview = stub_request(:post, "https://alexa.amazon.com.br/api/behaviors/preview").with(headers: { "csrf" => "C1" }).to_return(body: "")
      client = Alexa::Client.new(cookies: { "csrf" => "C1" })
      target = { serial: "G0C", type: "A3EH", customer_id: "CUST" }
      client.run_routine(target, "  boa   NOITE ")
      client.run_routine(target, "Hora do filme")
      expect(preview).to have_been_requested.twice
      bodies = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.select { |s| s.uri.path == "/api/behaviors/preview" }.map { |s| JSON.parse(s.body) }
      expect(bodies.map { |b| b["behaviorId"] }).to contain_exactly("amzn1.r.1", "amzn1.r.2")
      expect(bodies.find { |b| b["behaviorId"] == "amzn1.r.1" }["sequenceJson"]).to include("G0C")
      expect { client.run_routine(target, "nada") }.to raise_error(Alexa::Client::Error, /não encontrada/)
      stub_request(:get, "https://alexa.amazon.com.br/api/devices-v2/device?cached=true").to_return(status: 403)
      expect { client.devices }.to raise_error(Integrations::AuthError)
    end

    it "a Echo roda rotina como comando do ponto" do
      integration.update!(credentials: { "cookies" => { "csrf" => "C1" } }.to_json)
      echo = create(:device, site: site, name: "Echo", driver: "alexa", external_id: "G0C", integration: integration, address: { "device_type" => "A3EH", "customer_id" => "CUST" })
      speaker = create(:point, device: echo, site: site, name: "Falar", capability: "speaker")
      client = instance_double(Alexa::Client, run_routine: nil)
      Drivers::Alexa.new(client: client).execute(speaker, "routine", "Boa noite")
      expect(client).to have_received(:run_routine).with({ serial: "G0C", type: "A3EH", customer_id: "CUST" }, "Boa noite")
      expect(Points::Command.commands_for(speaker)).to include("routine")
    end
  end

  describe "ação Falar" do
    let(:integration) { Integration.create!(site: site, driver: "alexa", name: "Alexa", credentials: { "cookies" => { "csrf" => "1" } }.to_json) }
    let(:echo) { create(:device, site: site, name: "Echo Sala", driver: "alexa", integration: integration) }
    let(:speaker) { create(:point, device: echo, site: site, name: "Falar", capability: "speaker") }

    it "fala na Echo sem criar aviso, com ou sem o som de anúncio, e só aceita canais de fala" do
      a = build({ "triggers" => [ { "type" => "manual" } ],
                  "actions" => [ { "type" => "speak", "channels" => [ "alexa:#{speaker.id}" ], "message" => "Oi {{ site.name }}" },
                                 { "type" => "speak", "channels" => [ "alexa:#{speaker.id}" ], "message" => "Baixo", "chime" => false } ] })
      expect { expect(a.fire!({ "type" => "manual" }).status).to eq("done") }.not_to change(Notification, :count)
      expect(Command.order(:created_at).pluck(:command, :value)).to eq([ [ "announce", "Oi Local" ], [ "speak", "Baixo" ] ])
      expect(Notifier.speech_choices(site)).to eq([ [ "alexa:#{speaker.id}", "Falar na Echo Sala" ] ])

      errors = Automations::Dsl.errors({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "speak", "channels" => [ "in_app" ], "message" => "x" } ] }, site)
      expect(errors.join).to include("canais de fala")
      b = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "speak", "channels" => [ "alexa:#{SecureRandom.uuid}" ], "message" => "x" } ] })
      expect(b.fire!({ "type" => "manual" }).status).to eq("failed")
      c = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "speak", "channels" => [ "alexa:#{speaker.id}" ], "message" => "{{ nada }}" } ] })
      expect(c.fire!({ "type" => "manual" }).status).to eq("failed")
      expect(a.simulate!(definition: a.definition).steps.pluck("result")).to include("simulated")
    end
  end

  # Aberto/fechado: um tipo de câmera e um canal de fala que não existem no
  # código entram só pelo registro (stub_const), sem mudar o núcleo.
  describe "plugins falsos" do
    it "uma integração de câmera nova vira aparelho go2rtc com vídeo e movimento sem mexer no núcleo" do
      fake = Class.new(Integrations::Plugin) do
        describe key: "cam_falsa", title: "Câmera de teste", icon: "video-camera", description: "Só no spec."
        def self.setup(site, _form) = outcome(:found, integration: new_integration(site).tap(&:save!))
        def self.inventory(_integration)
          [ { "id" => "f1", "kind" => "go2rtc", "name" => "Câmera falsa", "address" => { "host" => "10.9.9.9" },
              "points" => [ { "name" => "Vídeo", "capability" => "stream", "history" => "none", "address" => { "path" => "/x" } },
                            { "name" => "Movimento", "capability" => "motion", "address" => { "onvif" => "motion" } } ] } ]
        end
      end
      stub_const("Integrations::CamFalsaPlugin", fake)
      stub_const("Integrations::PLUGINS", Integrations::PLUGINS + %w[CamFalsaPlugin])

      expect(Integrations.plugin("cam_falsa")).to eq(fake)
      integration = fake.setup(site, {}).integration
      expect(Integrations.sync!(integration)).to include(found: 1)
      Integrations.adopt!(integration, "f1" => "")
      cam = site.devices.find_by!(name: "Câmera falsa")
      expect(Drivers::Go2rtc.source(cam.points.find_by!(capability: "stream"))).to eq("rtsp://10.9.9.9:554/x")
      expect(Onvif::Listener.motion_points.pluck(:device_id)).to eq([ cam.id ])
    end

    it "um canal de fala novo aparece na ação Falar e recebe o texto sem mexer no núcleo" do
      said = []
      voice = Module.new do
        define_singleton_method(:owns?) { |c| c.start_with?("voz:") }
        define_singleton_method(:choices) { |_site| [ [ "voz:1", "Falar no alto-falante de teste" ] ] }
        define_singleton_method(:label) { |_c| "Alto-falante de teste" }
        define_singleton_method(:capabilities) { %i[text] }
        define_singleton_method(:deliver) { |_c, _list| nil }
        define_singleton_method(:speak) { |c, text, chime:| said << [ c, text, chime ] }
      end
      stub_const("Notifier::Channels::Voz", voice)
      stub_const("Notifier::CHANNELS", Notifier::CHANNELS + %w[Voz])

      expect(Notifier.speech_choices(site)).to eq([ [ "voz:1", "Falar no alto-falante de teste" ] ])
      a = build({ "triggers" => [ { "type" => "manual" } ], "actions" => [ { "type" => "speak", "channels" => [ "voz:1" ], "message" => "Olá {{ site.name }}" } ] })
      expect(a.fire!({ "type" => "manual" }).status).to eq("done")
      expect(said).to eq([ [ "voz:1", "Olá Local", true ] ])
    end
  end
end
