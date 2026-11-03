require "rails_helper"

# ondaC2 (paridade HA, grupo 6): navegador de mídia e fontes (C8), tocar e
# falar em todos os players + grupos (C9), câmeras com PTZ, gravação própria
# e áudio de duas vias (C10). Respostas gravadas (WebMock); nada de aparelho real.
RSpec.describe "ondaC2: mídia e câmeras" do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:media_dir) { Pathname(Dir.mktmpdir("ma-media")) }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  around do |ex|
    vars = { "MEDIA_DIR" => media_dir.join("m").to_s, "RECORDINGS_DIR" => media_dir.join("r").to_s, "MEDIA_PUBLIC_URL" => "http://ma.local", "GO2RTC_URL" => "http://go2rtc:1984" }
    old = vars.keys.to_h { |k| [ k, ENV.fetch(k, nil) ] }
    vars.each { |k, v| ENV[k] = v }
    ex.run
  ensure
    old.each { |k, v| ENV[k] = v }
    FileUtils.rm_rf(media_dir)
  end

  def soap_ok(url, action, inner = "")
    stub_request(:post, url).with(headers: { "SOAPACTION" => /##{action}\z/ })
                            .to_return(body: "<s:Envelope><s:Body><u:#{action}Response>#{inner}</u:#{action}Response></s:Body></s:Envelope>")
  end

  def run(point, command, value = nil) = ExecuteCommandJob.perform_now(Points::Command.call(point, command, value, source: "web").id)

  def dlna_player(name: "TV da sala")
    d = create(:device, site: site, name: name, driver: "dlna",
                        address: { "host" => "10.0.0.9", "av" => "http://10.0.0.9:9197/av", "rc" => "http://10.0.0.9:9197/rc" })
    create(:point, device: d, name: "Mídia", capability: "media", writable: true, address: { "supports" => Drivers::Dlna::SUPPORTS })
  end

  def camera(address = {})
    d = create(:device, site: site, name: "Câmera do portão", driver: "go2rtc", address: { "host" => "10.0.0.20", "port" => 554, "onvif_port" => 80 })
    create(:point, device: d, name: "Vídeo", capability: "stream", writable: true, address: { "path" => "/s1", "profile" => "P1" }.merge(address))
  end

  describe "C8: fontes de mídia por registro" do
    it "uma fonte falsa entra por stub_const e é navegada e tocada sem mexer no núcleo" do
      fake = Class.new(MediaSources::Source) do
        describe key: "fake", title: "Fonte falsa", icon: "music-note", description: "Só no teste."
        texts en: { title: "Fake source", description: "Test only." }, es: { title: "Fuente falsa", description: "Solo en la prueba." }
        def self.browse(_site, path, query: nil) = page("Raiz", nil, [ item(id: "a.mp3", title: "Música A #{path}#{query}", kind: "audio") ])
        def self.media_url(_site, id) = "http://fake/#{id}"
      end
      stub_const("MediaSources::Fake", fake)
      stub_const("MediaSources::PLUGINS", MediaSources::PLUGINS + %w[Fake])
      expect(MediaSources.for("fake")).to eq(fake)
      expect(MediaSources.available(site)).to include(fake)
      expect(fake.browse(site, "").items.first.title).to eq("Música A ")
      expect(fake.media_url(site, "a.mp3")).to eq("http://fake/a.mp3")
    end

    it "pasta local: cria pasta, envia, lista com link assinado e não sai da raiz" do
      MediaSources::Local.mkdir(site, "", "Rock")
      file = Rack::Test::UploadedFile.new(StringIO.new("ID3data"), "audio/mpeg", original_filename: "faixa.mp3")
      MediaSources::Local.upload(site, "Rock", file)
      page = MediaSources::Local.browse(site, "Rock")
      expect(page.items.map(&:title)).to eq([ "faixa.mp3" ])
      expect(page.parent).to eq("")
      url = MediaSources::Local.media_url(site, "Rock/faixa.mp3")
      expect(url).to start_with("http://ma.local/midia/arquivo/faixa.mp3?t=")
      expect(MediaSources.file_for(Rack::Utils.parse_query(URI(url).query)["t"]).read).to eq("ID3data")
      expect { MediaSources::Local.browse(site, "../..") }.to raise_error(ArgumentError)
      expect { MediaSources::Local.mkdir(site, "", "..") }.to raise_error(ArgumentError)
      bad = Rack::Test::UploadedFile.new(StringIO.new("x"), "text/plain", original_filename: "nota.txt")
      expect { MediaSources::Local.upload(site, "", bad) }.to raise_error(ArgumentError)
      expect(MediaSources.file_for("adulterado")).to be_nil
      MediaSources::Local.delete(site, "Rock")
      expect(MediaSources::Local.browse(site, "").items).to be_empty
    end

    it "rádios pelo radio-browser e servidores DLNA pelo ContentDirectory" do
      station = { "stationuuid" => "a" * 8 + "-1111-2222-3333-" + "b" * 12, "name" => "Rádio Teste", "url_resolved" => "https://r.example/stream.mp3", "country" => "Brazil", "tags" => "mpb,samba" }
      stub_request(:get, %r{radio-browser.info/json/stations/bycountrycodeexact/BR}).to_return(body: [ station ].to_json)
      stub_request(:get, %r{radio-browser.info/json/stations/byuuid/}).to_return(body: [ station ].to_json)
      allow(SafeHttp).to receive(:check!).and_return("1.2.3.4")
      page = MediaSources::RadioBrowser.browse(site, "country")
      expect(page.items.first).to have_attributes(title: "Rádio Teste", kind: "radio", subtitle: "Brazil · mpb, samba")
      expect(MediaSources::RadioBrowser.media_url(site, station["stationuuid"])).to eq("https://r.example/stream.mp3")

      allow(Ssdp).to receive(:search).and_return([ { "host" => "10.0.0.5", "txt" => { "location" => "http://10.0.0.5:8200/rootDesc.xml" } } ])
      stub_request(:get, "http://10.0.0.5:8200/rootDesc.xml").to_return(body: "<root><device><friendlyName>NAS</friendlyName><UDN>uuid:nas-1</UDN><serviceList>" \
                                                                             "<service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>/ctl/ContentDir</controlURL></service></serviceList></device></root>")
      didl = CGI.escapeHTML('<DIDL-Lite><container id="64"><dc:title>Músicas</dc:title></container><item id="64$1"><dc:title>Samba</dc:title>' \
                            '<upnp:class>object.item.audioItem.musicTrack</upnp:class><res protocolInfo="http-get:*:audio/mpeg:*">http://10.0.0.5:8200/MediaItems/1.mp3</res></item></DIDL-Lite>')
      soap_ok("http://10.0.0.5:8200/ctl/ContentDir", "Browse", "<Result>#{didl}</Result>")
      expect(MediaSources::Dlna.browse(site, "").items.map(&:title)).to eq([ "NAS" ])
      items = MediaSources::Dlna.browse(site, "nas-1").items
      expect(items.map { |i| [ i.title, i.kind ] }).to eq([ [ "Músicas", "folder" ], [ "Samba", "audio" ] ])
      expect(MediaSources::Dlna.media_url(site, "nas-1/64$1")).to eq("http://10.0.0.5:8200/MediaItems/1.mp3")
    end
  end

  describe "C9: tocar e falar em todos os players, grupos" do
    it "reprodutor DLNA: lê o estado e toca um endereço com metadado DIDL" do
      tv = dlna_player
      soap_ok("http://10.0.0.9:9197/av", "GetTransportInfo", "<CurrentTransportState>PLAYING</CurrentTransportState>")
      soap_ok("http://10.0.0.9:9197/av", "GetPositionInfo", "<TrackMetaData>#{CGI.escapeHTML('<DIDL-Lite><item><dc:title>Aquarela</dc:title></item></DIDL-Lite>')}</TrackMetaData>")
      soap_ok("http://10.0.0.9:9197/rc", "GetVolume", "<CurrentVolume>12</CurrentVolume>")
      soap_ok("http://10.0.0.9:9197/rc", "GetMute", "<CurrentMute>0</CurrentMute>")
      set = stub_request(:post, "http://10.0.0.9:9197/av").with(body: /SetAVTransportURI.*http:\/\/ma.local\/a.mp3.*protocolInfo=&quot;http-get:\*:audio\/mpeg:\*/m).to_return(body: "<ok/>")
      play = soap_ok("http://10.0.0.9:9197/av", "Play")
      run(tv, "play_media", "http://ma.local/a.mp3")
      expect([ set, play ]).to all(have_been_requested)
      expect(tv.reload.value).to include("state" => "playing", "title" => "Aquarela", "volume" => 12)
    end

    it "plugin DLNA acha as URLs de controle na descrição" do
      allow(Ssdp).to receive(:search).and_return([])
      stub_request(:get, "http://10.0.0.9:9197/description.xml").to_return(body: "<root><device><friendlyName>TV Quarto</friendlyName><UDN>uuid:tv-2</UDN><serviceList>" \
                                                                             "<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/upnp/control/AVTransport1</controlURL></service>" \
                                                                             "<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/upnp/control/RenderingControl1</controlURL></service>" \
                                                                             "</serviceList></device></root>")
      integration = Integration.new(site: site, settings: { "host" => "10.0.0.9", "port" => 9197 }, name: "TV")
      entry = Integrations::DlnaPlugin.probe(integration)
      expect(entry).to include("id" => "dlna:tv-2", "kind" => "dlna", "name" => "TV Quarto")
      expect(entry["address"]).to include("av" => "http://10.0.0.9:9197/upnp/control/AVTransport1", "rc" => "http://10.0.0.9:9197/upnp/control/RenderingControl1")
    end

    it "Sonos: favoritos como biblioteca e grupo nativo (join/unjoin)" do
      a = create(:device, site: site, name: "Sala", driver: "sonos", address: { "host" => "10.0.0.80" })
      b = create(:device, site: site, name: "Cozinha", driver: "sonos", address: { "host" => "10.0.0.81" })
      pa = create(:point, device: a, name: "Mídia", capability: "media", writable: true)
      pb = create(:point, device: b, name: "Mídia", capability: "media", writable: true)
      didl = CGI.escapeHTML('<DIDL-Lite><item id="FV:2/3"><dc:title>Rádio Favorita</dc:title><res>x-sonosapi-stream:s1?sid=254</res><r:resMD>meta</r:resMD></item></DIDL-Lite>')
      soap_ok("http://10.0.0.80:1400/MediaServer/ContentDirectory/Control", "Browse", "<Result>#{didl}</Result>")
      page = MediaSources::Players.browse(site, pa.id)
      expect(page.items.map(&:title)).to eq([ "Rádio Favorita" ])
      expect(MediaSources::Players.player_ids(site, page.items.first.id)).to eq([ pa.id ])
      expect(MediaSources::Players.media_url(site, page.items.first.id)).to eq("FV:2/3")

      stub_request(:get, "http://10.0.0.80:1400/xml/device_description.xml").to_return(body: "<root><device><UDN>uuid:RINCON_A</UDN></device></root>")
      join = stub_request(:post, "http://10.0.0.81:1400/MediaRenderer/AVTransport/Control").with(body: /x-rincon:RINCON_A/).to_return(body: "<ok/>")
      allow(Drivers::Sonos).to receive(:poll)
      run(pb, "join", pa.id)
      expect(join).to have_been_requested
      leave = soap_ok("http://10.0.0.81:1400/MediaRenderer/AVTransport/Control", "BecomeCoordinatorOfStandaloneGroup")
      run(pb, "unjoin")
      expect(leave).to have_been_requested
      expect { Points::Command.call(pb, "join", pb.id, source: "web") }.to raise_error(Points::Command::Error)
    end

    it "canal de fala Player: TTS da instalação vira play_media em qualquer player" do
      tv = dlna_player
      allow(Ai::Audio).to receive(:speak).and_return(Ai::Audio::Result.new(data: { data: "ID3", media_type: "audio/mpeg" }, provider: "x", model: "y"))
      allow(Drivers::Dlna).to receive(:run)
      allow(Drivers::Dlna).to receive(:poll)
      channel = "player:#{tv.id}"
      expect(Notifier.speech_choices(site).map(&:first)).to include(channel)
      expect(Notifier.channel_label(channel)).to eq("Falar em TV da sala")
      Notifier.channel_for(channel).speak(channel, "Jantar pronto")
      expect(Command.order(:created_at).last).to have_attributes(point_id: tv.id, command: "play_media", value: %r{\Ahttp://ma.local/rails/active_storage/blobs/})
    end

    it "grupo de players (helper Grupo) repassa tocar e volume a quem faz" do
      tv = dlna_player
      allow(Drivers::Dlna).to receive(:run)
      allow(Drivers::Dlna).to receive(:poll)
      tizen = create(:device, site: site, name: "TV Samsung", driver: "tizen", address: { "host" => "10.0.0.7" })
      tz = create(:point, device: tizen, name: "Mídia", capability: "media", writable: true, address: { "supports" => Drivers::Tizen::SUPPORTS })
      group = site.points.new(name: "Casa toda", helper: "group")
      HelperTypes::Group.assign(group, { "members" => [ tv.id, tz.id ] })
      expect(group.errors).to be_empty
      expect(group.capability).to eq("media")
      expect(HelperTypes::Group.commands(group)).to include("play_media", "volume")
      expect(HelperTypes::Group.media_value([ { "state" => "idle" }, { "state" => "playing", "title" => "X" } ])).to include("title" => "X")
    end
  end

  describe "C10: câmeras" do
    it "PTZ pelo ONVIF: anda e para sozinha; posição salva" do
      cam = camera("supports" => %w[record ptz])
      stub_request(:post, "http://10.0.0.20:80/onvif/device_service").with(body: /GetSystemDateAndTime/).to_return(body: "<x/>")
      stub_request(:post, "http://10.0.0.20:80/onvif/device_service").with(body: /GetCapabilities/)
                                                                     .to_return(body: "<e><PTZ><XAddr>http://10.0.0.20/onvif/ptz</XAddr></PTZ></e>")
      move = stub_request(:post, "http://10.0.0.20/onvif/ptz").with(body: /ContinuousMove.*P1.*PanTilt x="-0.5" y="0".*PT1S/m).to_return(body: "<ok/>")
      preset = stub_request(:post, "http://10.0.0.20/onvif/ptz").with(body: /GotoPreset.*<tptz:PresetToken>2</m).to_return(body: "<ok/>")
      run(cam, "ptz", "left")
      run(cam, "ptz", "preset:2")
      expect([ move, preset ]).to all(have_been_requested)
      expect { Points::Command.call(cam, "ptz", "girar", source: "web") }.to raise_error(Points::Command::Error)
      expect { Points::Command.call(cam, "play_media", "x", source: "web") }.to raise_error(Points::Command::Error, /não vale/)
    end

    it "alto-falante: o go2rtc toca o áudio na câmera" do
      cam = camera("supports" => %w[record play_media])
      put = stub_request(:put, %r{go2rtc:1984/api/streams}).to_return(status: 200)
      post = stub_request(:post, "http://go2rtc:1984/api/streams").with(query: hash_including("dst" => cam.id, "src" => "ffmpeg:http://ma.local/f.wav#audio=pcma#input=file"))
                                                                  .to_return(status: 200)
      allow(Drivers::Go2rtc).to receive(:source).and_return("rtsp://10.0.0.20/s1")
      run(cam, "play_media", "http://ma.local/f.wav")
      expect(post).to have_been_requested
      expect(put).not_to have_been_requested
    end

    it "grava pelo go2rtc, grava por movimento e apaga pela retenção" do
      cam = camera("supports" => %w[record], "record" => { "mode" => "events", "retention_days" => 2, "event_s" => 10 })
      allow(Drivers::Go2rtc).to receive(:source).and_return("rtsp://10.0.0.20/s1")
      stub_request(:get, "http://go2rtc:1984/api/stream.mp4").with(query: { "src" => cam.id, "duration" => "10" }).to_return(body: "MP4DATA")
      rec = Recordings.record!(cam, 10, "manual")
      expect(rec).to have_attributes(bytes: 7, trigger: "manual")
      expect(rec.path.read).to eq("MP4DATA")
      expect(MediaSources::Recordings.browse(site, "").items.map(&:title)).to eq([ "Câmera do portão" ])
      expect(MediaSources::Recordings.media_url(site, rec.id)).to include("/midia/arquivo/")

      motion = create(:point, device: cam.device, name: "Movimento", capability: "motion")
      expect { motion.report!(true) }.to have_enqueued_job(CameraRecordJob).with(cam.id, 10, "event")
      expect { Points::Command.call(cam, "record", 30, source: "web").then { |c| ExecuteCommandJob.perform_now(c.id) } }.to have_enqueued_job(CameraRecordJob).with(cam.id, 30, "manual")

      rec.update!(started_at: 3.days.ago)
      expect(Recordings.purge!).to eq(1)
      expect(rec.path).not_to exist
      expect(CameraRecording.count).to eq(0)
    end

    it "gravação contínua: o Recorder grava trechos enquanto a câmera estiver no modo" do
      cam = camera("record" => { "mode" => "continuous" })
      allow(Recordings).to receive(:record!)
      Recordings::Recorder.run(cam.id, rounds: 2)
      expect(Recordings).to have_received(:record!).twice
      cam.update!(address: cam.address.merge("record" => { "mode" => "off" }))
      Recordings::Recorder.run(cam.id, rounds: 5)
      expect(Recordings).to have_received(:record!).twice
    end
  end
end
