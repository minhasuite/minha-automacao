# Spotify (Pacote 1) pela Web API oficial com o app da PRÓPRIA pessoa (client
# id e secret criados no painel do Spotify, cifrados na integração). OAuth
# como o da Agenda: refresh token nas credenciais, access token (1 h) renovado
# aqui quando vence ou quando a API recusa (401, uma vez). Hosts fixos da
# API pelo SafeHttp.
module Spotify
  AUTH = "https://accounts.spotify.com/authorize".freeze
  TOKEN = "https://accounts.spotify.com/api/token".freeze
  API = "https://api.spotify.com/v1".freeze
  SCOPE = "user-read-playback-state user-modify-playback-state user-read-currently-playing playlist-read-private".freeze
  NO_DEVICE = "Abra o Spotify em algum aparelho (celular, computador ou caixa) e tente de novo.".freeze

  module_function

  def auth_url(integration, redirect_uri, state)
    query = { client_id: integration.secrets["client_id"], response_type: "code", redirect_uri: redirect_uri, scope: SCOPE, state: state }
    "#{AUTH}?#{URI.encode_www_form(query)}"
  end

  # code → {"refresh_token", "access_token", "expires_at"}.
  def exchange(integration, code, redirect_uri)
    raise Integrations::Error, "Sem o código do Spotify." if code.blank?

    tokens(integration, grant_type: "authorization_code", code: code, redirect_uri: redirect_uri)
  end

  def access_token(integration, force: false)
    s = integration.secrets
    raise Integrations.auth(Integrations::Error.new("Falta entrar com o Spotify.")) if s["refresh_token"].blank?
    return s["access_token"] if !force && s["access_token"].present? && s["expires_at"].to_i > Time.current.to_i + 60

    fresh = tokens(integration, grant_type: "refresh_token", refresh_token: s["refresh_token"])
    integration.merge_secrets!(fresh)
    fresh["access_token"]
  end

  def tokens(integration, **form)
    s = integration.secrets
    basic = Base64.strict_encode64("#{s['client_id']}:#{s['client_secret']}")
    res = SafeHttp.request("POST", TOKEN, headers: { "Content-Type" => "application/x-www-form-urlencoded", "Authorization" => "Basic #{basic}" },
                                          body: URI.encode_www_form(form))
    body = parse(res)
    unless res.status == 200
      error = Integrations::Error.new(body["error_description"] || body["error"] || "erro #{res.status}")
      raise res.status.between?(400, 499) ? Integrations.auth(error) : error
    end

    { "access_token" => body["access_token"], "expires_at" => Time.current.to_i + body["expires_in"].to_i,
      "refresh_token" => body["refresh_token"] }.compact
  end

  # Estado do player → valor do ponto `media` (204 = nada tocando).
  def state(integration)
    res = call(integration, "GET", "/me/player")
    return { "state" => "idle" } if res.status == 204 || res.body.blank?
    raise Integrations::Error, parse(res).dig("error", "message") || "Spotify respondeu #{res.status}" if res.status >= 400

    p = parse(res)
    item = p["item"] || {}
    { "state" => p["is_playing"] ? "playing" : "paused", "title" => item["name"],
      "artist" => Array(item["artists"]).map { |a| a["name"] }.join(", ").presence || item.dig("show", "name"),
      "album" => item.dig("album", "name"), "app" => p.dig("device", "name"), "volume" => p.dig("device", "volume_percent") }.compact
  end

  # Comando do ponto → pedido na API. Sem aparelho ativo (404) = erro claro.
  def command(integration, cmd, value)
    method, path, body = request_for(cmd, value)
    res = call(integration, method, path, body)
    raise Integrations::Error, NO_DEVICE if res.status == 404
    raise Integrations::Error, parse(res).dig("error", "message") || "Spotify respondeu #{res.status}" if res.status >= 400
  end

  def request_for(cmd, value)
    case cmd # comandos da capacidade media
    when "resume" then [ "PUT", "/me/player/play" ]
    when "pause" then [ "PUT", "/me/player/pause" ]
    when "next" then [ "POST", "/me/player/next" ]
    when "previous" then [ "POST", "/me/player/previous" ]
    when "volume" then [ "PUT", "/me/player/volume?volume_percent=#{value.to_i}" ]
    when "play_media" then [ "PUT", "/me/player/play", play_body(value) ]
    else raise Integrations::Error, "O Spotify não faz \"#{cmd}\"."
    end
  end

  # spotify:track:… → {uris}; playlist/álbum/artista → {context_uri}. Aceita o link open.spotify.com.
  def play_body(value)
    uri = to_uri(value) or raise Integrations::Error, "Use um link ou URI do Spotify (faixa, playlist, álbum ou artista)."
    uri.start_with?("spotify:track:", "spotify:episode:") ? { "uris" => [ uri ] } : { "context_uri" => uri }
  end

  def to_uri(value)
    v = value.to_s.strip
    return v if v.match?(/\Aspotify:(track|episode|playlist|album|artist|show):[A-Za-z0-9]+\z/)

    m = v.match(%r{\Ahttps?://open\.spotify\.com/(?:intl-[a-z-]+/)?(track|episode|playlist|album|artist|show)/([A-Za-z0-9]+)}) or return
    "spotify:#{m[1]}:#{m[2]}"
  end

  # Pedido autenticado; 401 renova o token e repete uma vez.
  def call(integration, method, path, body = nil)
    send = lambda do |token|
      headers = { "Authorization" => "Bearer #{token}" }
      headers["Content-Type"] = "application/json" if body
      SafeHttp.request(method, "#{API}#{path}", headers: headers, body: body&.to_json || ("" if method != "GET"))
    end
    res = send.call(access_token(integration))
    res = send.call(access_token(integration, force: true)) if res.status == 401
    res
  end

  def parse(res)
    JSON.parse(res.body.presence || "{}")
  rescue JSON::ParserError
    {}
  end
end
