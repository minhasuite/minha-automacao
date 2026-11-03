require "socket"

module Integrations
  # Denon HEOS (catalogo): caixas e receivers HEOS pela CLI do HEOS (TCP 1255,
  # `heos://…`, resposta em JSON). Um aparelho por player da rede HEOS, como
  # player de mídia: tocar/pausar, próxima, volume, mudo e tocar um endereço.
  class HeosPlugin < SchemaPlugin
    describe key: "heos", title: "Denon HEOS", icon: "music-note",
             description: "Caixas e receivers Denon HEOS da rede: tocar, pausar, próxima, volume, mudo, o que está tocando e tocar um endereço de áudio."
    texts "pt-BR" => { hints: { host: "IP de qualquer caixa HEOS (as outras vêm junto)" } },
          en: { title: "Denon HEOS", description: "Denon HEOS speakers and receivers on your network: play, pause, next, volume, mute, what's playing and playing an audio URL.",
                hints: { host: "IP of any HEOS speaker (the others come along)" } },
          es: { title: "Denon HEOS", description: "Altavoces y receptores Denon HEOS de la red: reproducir, pausar, siguiente, volumen, silencio, lo que suena y reproducir una dirección de audio.",
                hints: { host: "IP de cualquier altavoz HEOS (los demás vienen juntos)" } }
    field :host, required: true
    ssdp "urn:schemas-denon-com:device:ACT-Denon:1"
    PORT = 1255
    SUPPORTS = %w[resume pause next previous volume volume_up volume_down mute play_media].freeze
    STATES = { "play" => "playing", "pause" => "paused", "stop" => "idle" }.freeze

    class << self
      # Comandos numa conexão → respostas {"heos", "payload"} (pula os avisos "command under process").
      def heos(host, *commands)
        Socket.tcp(host, PORT, connect_timeout: 4) do |s|
          commands.map do |cmd|
            s.write("heos://#{cmd}\r\n")
            loop do
              raise Integrations::Error, "HEOS: sem resposta" unless s.wait_readable(5)

              r = JSON.parse(s.gets("\r\n").to_s)
              next if r.dig("heos", "message").to_s.include?("command under process")
              raise Integrations::Error, "HEOS: #{r.dig('heos', 'message')}" if r.dig("heos", "result") == "fail"

              break r
            end
          end
        end
      rescue *LanPlugin::NET_ERRORS => e
        raise Integrations::Error, "HEOS: #{e.class.name.demodulize}"
      end

      def msg(r) = Rack::Utils.parse_query(r.dig("heos", "message").to_s)

      def entries(integration)
        host = conf(integration, :host)
        Array(heos(host, "player/get_players").first["payload"]).map do |p|
          entry(id: "heos:#{p['pid']}", name: p["name"], manufacturer: "Denon", model: p["model"], category: "Mídia", address: { "host" => host, "pid" => p["pid"].to_s },
                poll_s: 30, points: [ point("media", "media", name: text("points.player"), history: "none", address: { "supports" => SUPPORTS }) ])
        end
      end

      def read(device)
        pid = device.address["pid"]
        state, vol, mute, now = heos(device.address["host"], "player/get_play_state?pid=#{pid}", "player/get_volume?pid=#{pid}",
                                     "player/get_mute?pid=#{pid}", "player/get_now_playing_media?pid=#{pid}")
        media = now["payload"].to_h
        { "media" => { "state" => STATES.fetch(msg(state)["state"], "idle"), "volume" => msg(vol)["level"]&.to_i, "muted" => msg(mute)["state"] == "on",
                       "title" => media["song"].presence, "artist" => media["artist"].presence, "album" => media["album"].presence,
                       "image" => media["image_url"].presence }.compact }
      end

      def command(point, command, value)
        pid = point.device.address["pid"]
        cmd = case command
        when "resume" then "player/set_play_state?pid=#{pid}&state=play"
        when "pause" then "player/set_play_state?pid=#{pid}&state=pause"
        when "next" then "player/play_next?pid=#{pid}"
        when "previous" then "player/play_previous?pid=#{pid}"
        when "volume" then "player/set_volume?pid=#{pid}&level=#{value.to_i.clamp(0, 100)}"
        when "volume_up" then "player/volume_up?pid=#{pid}&step=5"
        when "volume_down" then "player/volume_down?pid=#{pid}&step=5"
        when "mute" then "player/set_mute?pid=#{pid}&state=#{value ? 'on' : 'off'}"
        when "play_media" then "browse/play_stream?pid=#{pid}&url=#{value}"
        end
        heos(point.device.address["host"], cmd)
      end
    end
  end
end
