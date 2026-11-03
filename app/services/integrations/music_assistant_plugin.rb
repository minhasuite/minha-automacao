module Integrations
  # Music Assistant (catalogo): os players do servidor Music Assistant (o app
  # `music_assistant` do catálogo de apps ou um servidor seu) pela API
  # WebSocket (`/ws`): cada player vira um ponto de mídia com tocar, pausar,
  # próxima, volume e tocar um item/URI da biblioteca.
  class MusicAssistantPlugin < SchemaPlugin
    describe key: "music_assistant", title: "Music Assistant", icon: "music-note",
             description: "Players do Music Assistant (Sonos, Chromecast, AirPlay, DLNA, Squeezebox…): o que toca, tocar, pausar, próxima, volume e tocar da biblioteca."
    texts "pt-BR" => { hints: { port: "8095" } }, en: { title: "Music Assistant", description: "Music Assistant players (Sonos, Chromecast, AirPlay, DLNA, Squeezebox…): what's playing, play, pause, next, volume and play from the library.",
                                                      hints: { port: "8095" } },
          es: { title: "Music Assistant", description: "Reproductores de Music Assistant (Sonos, Chromecast, AirPlay, DLNA, Squeezebox…): lo que suena, reproducir, pausar, siguiente, volumen y reproducir de la biblioteca.",
                hints: { port: "8095" } }
    field :host, required: true
    field :port, :number, default: 8095
    mdns "_mass._tcp"
    SUPPORTS = %w[resume pause next previous volume mute play_media].freeze
    STATES = { "playing" => "playing", "paused" => "paused", "idle" => "idle" }.freeze

    class << self
      def url(a) = "ws://#{a['host']}:#{a['port']}/ws"

      # Comandos numa conexão → resultados (pula a mensagem de boas-vindas e os eventos).
      def rpc(a, *cmds)
        WsClient.open(url(a)) do |ws|
          cmds.each_with_index.map do |(command, args), n|
            id = "ma#{n}"
            ws.send_json({ message_id: id, command: command, args: args || {} })
            loop do
              msg = ws.read_json(10) or raise(Integrations::Error, "Music Assistant: sem resposta")
              next unless msg["message_id"] == id
              raise Integrations::Error, "Music Assistant: #{msg['details'] || msg['error_code']}" if msg.key?("error_code")

              break msg["result"]
            end
          end
        end
      rescue WsClient::Error => e
        raise Integrations::Error, "Music Assistant: #{e.message}"
      end

      def addr(integration) = { "host" => conf(integration, :host), "port" => conf(integration, :port).to_i }

      def entries(integration)
        a = addr(integration)
        Array(rpc(a, [ "players/all" ]).first).select { |p| p["available"] != false && p["enabled"] != false }.map do |p|
          entry(id: "mass:#{p['player_id']}", name: p["display_name"].presence || p["name"], manufacturer: p.dig("device_info", "manufacturer").presence || title,
                model: p.dig("device_info", "model"), category: "Mídia", address: a.merge("player" => p["player_id"]), poll_s: 30,
                points: [ point("media", "media", name: text("points.player"), history: "none", address: { "supports" => SUPPORTS }) ])
        end
      end

      def read(device)
        p = Array(rpc(device.address, [ "players/all" ]).first).find { |x| x["player_id"] == device.address["player"] }.to_h
        m = p["current_media"].to_h
        { "media" => { "state" => p["powered"] == false ? "off" : STATES.fetch(p["state"].to_s, "idle"), "volume" => p["volume_level"], "muted" => p["volume_muted"],
                       "title" => m["title"].presence, "artist" => m["artist"].presence, "album" => m["album"].presence, "image" => m["image_url"].presence }.compact }
      end

      def command(point, command, value)
        id = point.device.address["player"]
        cmd = case command
        when "resume" then [ "players/cmd/play", { player_id: id } ]
        when "pause" then [ "players/cmd/pause", { player_id: id } ]
        when "next" then [ "players/cmd/next", { player_id: id } ]
        when "previous" then [ "players/cmd/previous", { player_id: id } ]
        when "volume" then [ "players/cmd/volume_set", { player_id: id, volume_level: value.to_i.clamp(0, 100) } ]
        when "mute" then [ "players/cmd/volume_mute", { player_id: id, muted: value == true } ]
        when "play_media" then [ "player_queues/play_media", { queue_id: id, media: value.to_s } ]
        end
        rpc(point.device.address, cmd)
      end
    end
  end
end
