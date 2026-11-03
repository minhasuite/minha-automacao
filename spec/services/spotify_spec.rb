require "rails_helper"

# Pacote 1: Spotify pela Web API com o app da própria pessoa (OAuth), ponto
# `media` e o comando `play_media` (tocar playlist/URI). Só WebMock.
RSpec.describe Integrations::SpotifyPlugin do
  let(:tenant) { create(:tenant) }
  let(:site) { create(:site) }
  let(:api) { "https://api.spotify.com/v1" }
  let(:token_url) { "https://accounts.spotify.com/api/token" }

  around { |ex| ActsAsTenant.with_tenant(tenant) { ex.run } }

  # Registro como os plugins de verdade (o núcleo não sabe quem é).
  before do
    stub_const("Integrations::PLUGINS", (Integrations::PLUGINS + %w[SpotifyPlugin]).uniq)
    stub_const("Drivers::REGISTRY", Drivers::REGISTRY.merge("spotify" => "Drivers::Spotify"))
    stub_const("Polling::DEVICES", Polling::DEVICES.merge("spotify" => "Drivers::Spotify"))
  end

  def params(**h) = ActionController::Parameters.new(h)

  def player(playing: true)
    { is_playing: playing, device: { name: "Celular", volume_percent: 40 },
      item: { name: "Garota de Ipanema", artists: [ { name: "Tom Jobim" } ], album: { name: "Getz/Gilberto" } } }.to_json
  end

  def connected
    i = described_class.setup(site, params(client_id: "cid", client_secret: "csec")).integration
    stub_request(:post, token_url).with(body: hash_including("grant_type" => "authorization_code", "code" => "C1"),
                                        headers: { "Authorization" => "Basic #{Base64.strict_encode64('cid:csec')}" })
                                  .to_return(body: { access_token: "A1", refresh_token: "R1", expires_in: 3600 }.to_json)
    stub_request(:get, "#{api}/me/player").to_return(status: 200, body: player)
    described_class.oauth_callback(i, { code: "C1", redirect_uri: "https://casa/integracoes/oauth/retorno" })
    i.reload
  end

  def media_point = site.points.find_by!(capability: "media")

  it "pede o app do Spotify, guarda client e tokens cifrados e monta a URL de consentimento" do
    expect(described_class.setup(site, params(client_id: "cid")).alert).to include("Client Secret")
    o = described_class.setup(site, params(client_id: "cid", client_secret: "csec"))
    expect([ o.to, o.integration.status ]).to eq([ :connect, "pending" ])
    url = described_class.connect_locals(o.integration, { redirect_uri: "https://casa/integracoes/oauth/retorno" })[:auth_url]
    q = Rack::Utils.parse_query(URI(url).query)
    expect(q).to include("client_id" => "cid", "response_type" => "code", "redirect_uri" => "https://casa/integracoes/oauth/retorno")
    expect(q["scope"]).to include("user-modify-playback-state", "playlist-read-private")
    expect(Integrations.from_oauth_state(q["state"])).to eq(o.integration.id)

    i = connected
    expect(i.secrets).to include("refresh_token" => "R1", "access_token" => "A1", "client_secret" => "csec")
    raw = Integration.connection.select_value("SELECT credentials FROM integrations WHERE id = '#{i.id}'")
    expect(raw).not_to include("refresh_token", "client_secret") # cifrado (o "R1" às vezes aparecia no base64 aleatório)
    device = site.devices.find_by!(driver: "spotify", external_id: "spotify:#{i.id}")
    expect(device.poll_s).to eq(30)
    expect(media_point.value).to eq("state" => "playing", "title" => "Garota de Ipanema", "artist" => "Tom Jobim", "album" => "Getz/Gilberto",
                                     "app" => "Celular", "volume" => 40)
    expect(Points::Command.commands_for(media_point)).to eq(%w[resume pause next previous volume play_media])
  end

  it "recusa do OAuth vira aviso na tela de conexão" do
    i = described_class.setup(site, params(client_id: "cid", client_secret: "csec")).integration
    stub_request(:post, token_url).to_return(status: 400, body: { error: "invalid_grant" }.to_json)
    o = described_class.oauth_callback(i, { code: "X", redirect_uri: "r" })
    expect([ o.to, o.alert ]).to eq([ :connect, "O Spotify recusou: invalid_grant" ])
  end

  it "renova o token vencido e, no 401, renova uma vez e repete" do
    i = connected
    travel 2.hours do
      stub_request(:post, token_url).with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "R1"))
                                    .to_return(body: { access_token: "A2", expires_in: 3600 }.to_json)
      stub_request(:get, "#{api}/me/player").with(headers: { "Authorization" => "Bearer A2" }).to_return(status: 204, body: "")
      expect(Spotify.state(i)).to eq("state" => "idle")
      expect(i.reload.secrets).to include("access_token" => "A2", "refresh_token" => "R1")
    end

    stub_request(:post, token_url).to_return(body: { access_token: "A3", expires_in: 3600 }.to_json)
    stub_request(:get, "#{api}/me/player").with(headers: { "Authorization" => "Bearer A2" }).to_return(status: 401, body: "{}")
    stub_request(:get, "#{api}/me/player").with(headers: { "Authorization" => "Bearer A3" }).to_return(status: 200, body: player(playing: false))
    i.merge_secrets!("expires_at" => 5.minutes.from_now.to_i, "access_token" => "A2")
    expect(Spotify.state(i)["state"]).to eq("paused")
  end

  it "comandos pelo ponto media: pausar, volume e tocar playlist por link (play_media)" do
    connected
    p = media_point
    pause = stub_request(:put, "#{api}/me/player/pause").to_return(status: 204)
    vol = stub_request(:put, "#{api}/me/player/volume?volume_percent=70").to_return(status: 204)
    play = stub_request(:put, "#{api}/me/player/play").with(body: { context_uri: "spotify:playlist:37i9dQZF1DX0XUsuxWHRQd" }.to_json).to_return(status: 204)

    %w[pause volume play_media].zip([ nil, 70, "https://open.spotify.com/intl-pt/playlist/37i9dQZF1DX0XUsuxWHRQd?si=abc" ]).each do |cmd, value|
      c = Points::Command.call(p, cmd, value, source: "automation")
      ExecuteCommandJob.perform_now(c.id)
      expect(c.reload.status).to eq("confirmed")
    end
    expect([ pause, vol, play ]).to all(have_been_requested)
    expect { Points::Command.call(p, "on", nil, source: "web") }.to raise_error(Points::Command::Error, /não vale/)
  end

  it "sem aparelho ativo o comando falha com instrução clara" do
    connected
    stub_request(:post, "#{api}/me/player/next").to_return(status: 404, body: { error: { message: "No active device found" } }.to_json)
    expect { Drivers::Spotify.new.execute(media_point, "next", nil) }.to raise_error(Integrations::Error, /Abra o Spotify/)
  end

  it "link ou URI do Spotify vira o corpo certo do play" do
    expect(Spotify.play_body("spotify:track:4uLU6hMCjMI75M1A2tKUQC")).to eq("uris" => [ "spotify:track:4uLU6hMCjMI75M1A2tKUQC" ])
    expect(Spotify.play_body("https://open.spotify.com/album/1A2GTWGtFfWp7KSQTwWOyo")).to eq("context_uri" => "spotify:album:1A2GTWGtFfWp7KSQTwWOyo")
    expect { Spotify.play_body("tocar algo") }.to raise_error(Integrations::Error, /link ou URI/)
  end

  it "leitura periódica pelo Polling e indisponível na falha" do
    i = connected
    device = site.devices.find_by!(driver: "spotify")
    stub_request(:get, "#{api}/me/player").to_return(status: 500, body: "{}")
    device.update_columns(polled_at: nil)
    expect(Polling.poll_device(device.id)).to be(false)
    expect(media_point.reload.quality).to eq("unavailable")
    stub_request(:get, "#{api}/me/player").to_return(status: 200, body: player)
    expect(Polling.poll_device(device.id)).to be(true)
    expect(media_point.reload).to have_attributes(quality: "good")
    expect(i.plugin).to eq(described_class)
  end
end
