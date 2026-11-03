require "rails_helper"

# ondaC2: telas de mídia (/locais/:id/midia), arquivo por link assinado,
# câmera na página do ponto (PTZ, gravação, falar) e o "Falar" do app pela API.
RSpec.describe "ondaC2: telas de mídia e câmeras" do
  let(:user) { create(:user) }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:media_dir) { Pathname(Dir.mktmpdir("ma-media")) }
  let!(:tv) do
    within(tenant) do
      d = create(:device, site: site, name: "TV da sala", driver: "dlna", address: { "host" => "10.0.0.9", "av" => "http://10.0.0.9/av", "rc" => "http://10.0.0.9/rc" })
      create(:point, device: d, name: "Mídia", capability: "media", writable: true, value: { "state" => "playing", "title" => "Aquarela", "volume" => 30 },
                     address: { "supports" => Drivers::Dlna::SUPPORTS })
    end
  end
  let!(:cam) do
    within(tenant) do
      d = create(:device, site: site, driver: "go2rtc", name: "Câmera do portão", address: { "host" => "10.0.0.20" })
      create(:point, device: d, name: "Vídeo", capability: "stream", address: { "path" => "/s1" })
    end
  end

  around do |ex|
    old = %w[MEDIA_DIR MEDIA_PUBLIC_URL].to_h { |k| [ k, ENV.fetch(k, nil) ] }
    ENV["MEDIA_DIR"] = media_dir.to_s
    ENV["MEDIA_PUBLIC_URL"] = "http://ma.local"
    ex.run
  ensure
    old.each { |k, v| ENV[k] = v }
    FileUtils.rm_rf(media_dir)
  end

  before { post("/entrar", params: { email: user.email, password: "12345678" }) }

  it "Mídia: players com controles, falar e as bibliotecas" do
    get "/locais/#{site.id}/midia"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("TV da sala", "Aquarela", "Falar num player", "Arquivos de mídia", "Rádios", "Servidores DLNA")
    expect(response.body).not_to include("Bibliotecas dos players") # nenhum player com biblioteca

    allow(Drivers::Dlna).to receive(:run)
    allow(Drivers::Dlna).to receive(:poll)
    post "/locais/#{site.id}/midia/players/#{tv.id}", params: { command: "volume", value: "45" }
    expect(response).to redirect_to("/locais/#{site.id}/midia#player-#{tv.id}")
    allow(Ai::Audio).to receive(:speak).and_return(Ai::Audio::Result.new(data: { data: "ID3", media_type: "audio/mpeg" }, provider: "x", model: "y"))
    post "/locais/#{site.id}/midia/falar", params: { player_id: tv.id, text: "Jantar pronto" }
    expect(flash[:notice]).to eq("Mandado para TV da sala.")
    expect(within(tenant) { Command.order(:created_at).last }).to have_attributes(command: "play_media", value: %r{\Ahttp://ma.local/})
  end

  it "arquivos: envia, navega, toca na TV e o player baixa pelo link assinado (com Range)" do
    post "/locais/#{site.id}/midia/pastas", params: { path: "", name: "Festa" }
    post "/locais/#{site.id}/midia/arquivos", params: { path: "Festa", files: [ Rack::Test::UploadedFile.new(StringIO.new("0123456789"), "audio/mpeg", original_filename: "abertura.mp3") ] }
    expect(flash[:notice]).to eq("Pronto.")
    get "/locais/#{site.id}/midia/fontes/local", params: { path: "Festa", item: "Festa/abertura.mp3" }
    expect(response.body).to include("abertura.mp3", "Tocar em", "<audio")

    post "/locais/#{site.id}/midia/tocar", params: { source: "local", item: "Festa/abertura.mp3", player_id: tv.id, path: "Festa" }
    played = within(tenant) { Command.order(:created_at).last.value }
    expect(played).to start_with("http://ma.local/midia/arquivo/abertura.mp3?t=")

    reset! # o player não tem sessão
    get URI(played).request_uri, headers: { "Range" => "bytes=2-4" }
    expect(response).to have_http_status(:partial_content)
    expect(response.body).to eq("234")
    get "/midia/arquivo/abertura.mp3", params: { t: "adulterado" }
    expect(response).to have_http_status(:not_found)
  end

  it "fonte falsa por stub_const aparece na tela sem mexer no núcleo" do
    fake = Class.new(MediaSources::Source) do
      describe key: "fake", title: "Fonte falsa", icon: "music-note", description: "Só no teste."
      texts en: { title: "Fake", description: "Test." }, es: { title: "Falsa", description: "Prueba." }
      def self.browse(_site, _path, query: nil) = page("Raiz", nil, [ item(id: "x", title: "Item falso", kind: "audio") ])
    end
    stub_const("MediaSources::Fake", fake)
    stub_const("MediaSources::PLUGINS", MediaSources::PLUGINS + %w[Fake])
    get "/locais/#{site.id}/midia"
    expect(response.body).to include("Fonte falsa")
    get "/locais/#{site.id}/midia/fontes/fake"
    expect(response.body).to include("Item falso")
  end

  it "câmera: ajustes ligam PTZ, alto-falante e gravação; a página mostra os controles" do
    patch "/cameras/#{cam.id}/ajustes", params: { mode: "events", retention_days: "3", event_s: "20", ptz: "1", talk: "1" }
    cam.reload
    expect(cam.writable).to be true
    expect(cam.address).to include("supports" => %w[record ptz play_media], "record" => { "mode" => "events", "retention_days" => 3, "event_s" => 20 })
    get "/pontos/#{cam.id}"
    expect(response.body).to include("Mover a câmera", "Falar", "Gravar 20 s agora", "Grava quando há movimento · guarda 3 dias")
  end

  it "API: o app manda o áudio gravado e a câmera toca (play_media)" do
    within(tenant) { cam.update!(writable: true, address: cam.address.merge("supports" => %w[record play_media])) }
    allow(Drivers::Go2rtc).to receive(:play_audio)
    audio = Rack::Test::UploadedFile.new(StringIO.new("RIFFxxxx"), "audio/wav", original_filename: "fala.wav")
    post "/api/v1/points/#{cam.id}/talk", params: { audio: audio }, headers: auth_headers(user)
    expect(response).to have_http_status(:accepted)
    within(tenant) { ExecuteCommandJob.perform_now(Command.order(:created_at).last.id) }
    expect(Drivers::Go2rtc).to have_received(:play_audio).with(anything, %r{\Ahttp://ma.local/rails/active_storage/blobs/})
  end

  # As mesmas telas no app (telas do servidor, appweb). APPWEB_DUMP=dir grava as fixtures do app.
  it "abre Mídia, um arquivo e a câmera pelo app" do
    within(tenant) do
      MediaSources::Local.mkdir(site, "", "Festa")
      MediaSources::Local.upload(site, "Festa", Rack::Test::UploadedFile.new(StringIO.new("ID3"), "audio/mpeg", original_filename: "abertura.mp3"))
      cam.update!(writable: true, address: cam.address.merge("supports" => %w[record ptz play_media], "talk" => true, "record" => { "mode" => "events" }))
    end
    dir = ENV["APPWEB_DUMP"].presence
    { "midia" => "/locais/#{site.id}/midia", "midia_arquivo" => "/locais/#{site.id}/midia/fontes/local?path=Festa&item=Festa/abertura.mp3",
      "midia_radios" => "/locais/#{site.id}/midia/fontes/radios", "ponto_camera" => "/pontos/#{cam.id}" }.each do |name, path|
      get "/api/v1/screen", params: { path: path }, headers: auth_headers(user)
      expect(response.parsed_body.dig("meta", "status")).to eq(200), path
      blocks = response.parsed_body.dig("data", "page", "blocks").to_json
      expect(blocks).to include("Tocar em") if name == "midia_arquivo"
      expect(blocks).to include("Mover a câmera", "Ajustes da câmera") if name == "ponto_camera"
      File.write("#{dir}/#{name}.json", JSON.pretty_generate(response.parsed_body)) if dir
    end
  end
end
