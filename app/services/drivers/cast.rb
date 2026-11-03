module Drivers
  # Chromecast / Google Cast (Pacote 1): protocolo CastV2 na porta 8009, TLS
  # com certificado do próprio aparelho (sem verificação, só na rede de
  # casa) e CastMessage em protobuf (`Proto`), quadro com 4 bytes de
  # tamanho. Receptor (`receiver-0`): volume, mudo, app aberto, abrir e
  # fechar app; mídia pelo transportId do app: estado, título e
  # play/pause/próxima. Tocar URL = Default Media Receiver (CC1AD845).
  class Cast < MediaLan
    PORT = 8009
    APP_MEDIA = "CC1AD845".freeze
    SUPPORTS = %w[off resume pause next previous volume mute play_media].freeze
    PLAYER = { "PLAYING" => "playing", "PAUSED" => "paused", "BUFFERING" => "buffering", "IDLE" => "idle" }.freeze
    MEDIA_CMDS = { "resume" => "PLAY", "pause" => "PAUSE", "next" => "QUEUE_NEXT", "previous" => "QUEUE_PREV" }.freeze
    TYPES = { ".mp3" => "audio/mpeg", ".m4a" => "audio/mp4", ".aac" => "audio/aac", ".ogg" => "audio/ogg", ".wav" => "audio/wav",
              ".flac" => "audio/flac", ".mp4" => "video/mp4", ".mkv" => "video/x-matroska", ".webm" => "video/webm",
              ".m3u8" => "application/x-mpegURL", ".jpg" => "image/jpeg", ".png" => "image/png" }.freeze

    class << self
      def client(device) = Client.new(host(device), port(device, PORT))
      def read(device) = client(device).session { |c| state(c) }

      def state(c)
        st = c.receiver_status
        vol = st["volume"] || {}
        app = c.app(st)
        v = { "state" => app ? "on" : "idle", "app" => app&.dig("displayName"), "volume" => vol["level"] && (vol["level"] * 100).round, "muted" => vol["muted"] }
        if app && (m = c.media_status(app["transportId"]))
          meta = m.dig("media", "metadata") || {}
          v.merge!("state" => PLAYER.fetch(m["playerState"], "on"), "title" => meta["title"], "artist" => meta["artist"] || meta["subtitle"], "album" => meta["albumName"])
        end
        v.compact
      end

      def run(device, command, value)
        client(device).session do |c|
          case command
          when "volume" then c.receiver("SET_VOLUME", "volume" => { "level" => value / 100.0 })
          when "mute" then c.receiver("SET_VOLUME", "volume" => { "muted" => value })
          when "off" then (app = c.app) && c.receiver("STOP", "sessionId" => app["sessionId"])
          when "play_media" then c.load(value, TYPES.fetch(File.extname(URI.parse(value).path.to_s).downcase, "video/mp4"))
          else
            app = c.app or raise self::Error, "Nada tocando no Chromecast."
            m = c.media_status(app["transportId"]) or raise self::Error, "Nada tocando no Chromecast."
            c.media(app["transportId"], MEDIA_CMDS.fetch(command), "mediaSessionId" => m["mediaSessionId"])
          end
        end
      rescue URI::InvalidURIError
        raise self::Error, "Endereço inválido para tocar."
      end
    end

    # Uma sessão CastV2 (abre, conecta no receptor, responde PING, fecha).
    class Client
      NS_CONN = "urn:x-cast:com.google.cast.tp.connection".freeze
      NS_HB = "urn:x-cast:com.google.cast.tp.heartbeat".freeze
      NS_RECV = "urn:x-cast:com.google.cast.receiver".freeze
      NS_MEDIA = "urn:x-cast:com.google.cast.media".freeze
      SENDER = "sender-0".freeze

      def initialize(host, port, timeout: 5)
        @host = host
        @port = port
        @timeout = timeout
        @req = 0
        @connected = Set.new
      end

      def session
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE # certificado do próprio Chromecast
        @sock = OpenSSL::SSL::SSLSocket.new(Socket.tcp(@host, @port, connect_timeout: @timeout), ctx)
        @sock.sync_close = true
        @sock.connect
        send_msg(NS_CONN, "receiver-0", "type" => "CONNECT")
        yield self
      ensure
        @sock&.close
      end

      def send_msg(ns, dest, payload)
        msg = Proto.encode([ [ 1, :enum, 0 ], [ 2, :string, SENDER ], [ 3, :string, dest ], [ 4, :string, ns ], [ 5, :enum, 0 ], [ 6, :string, payload.to_json ] ])
        @sock.write([ msg.bytesize ].pack("N") + msg)
      end

      def read_msg
        f = Proto.decode(read_exact(read_exact(4).unpack1("N")))
        { "src" => Proto.string(f[2].first), "ns" => Proto.string(f[4].first), "data" => JSON.parse(Proto.string(f[6].first) || "{}") }
      end

      # Pedido com requestId; devolve a resposta dele (PING no meio vira PONG).
      def request(ns, dest, payload)
        id = (@req += 1)
        send_msg(ns, dest, payload.merge("requestId" => id))
        loop do
          m = read_msg
          send_msg(NS_HB, m["src"], "type" => "PONG") if m["data"]["type"] == "PING"
          return m["data"] if m["data"]["requestId"] == id
        end
      end

      def receiver(type, extra = {}) = request(NS_RECV, "receiver-0", { "type" => type }.merge(extra))
      def receiver_status = receiver("GET_STATUS")["status"] || {}
      def app(status = receiver_status) = Array(status["applications"]).find { |a| !a["isIdleScreen"] }

      def media_status(transport)
        Array(media(transport, "GET_STATUS")["status"]).first
      end

      def media(transport, type, extra = {})
        send_msg(NS_CONN, transport, "type" => "CONNECT") if @connected.add?(transport)
        request(NS_MEDIA, transport, { "type" => type }.merge(extra))
      end

      def load(url, content_type)
        status = receiver("LAUNCH", "appId" => APP_MEDIA)["status"] || {}
        app = Array(status["applications"]).find { |a| a["appId"] == APP_MEDIA } or raise Cast::Error, "O Chromecast não abriu o reprodutor."
        media(app["transportId"], "LOAD", "media" => { "contentId" => url, "contentType" => content_type, "streamType" => "BUFFERED" }, "autoplay" => true)
      end

      private

      def read_exact(n)
        out = +"".b
        while out.bytesize < n
          raise Cast::Error, "O Chromecast não respondeu." unless @sock.pending.positive? || IO.select([ @sock ], nil, nil, @timeout)

          chunk = @sock.read_nonblock(n - out.bytesize, exception: false)
          raise Cast::Error, "O Chromecast fechou a conexão." if chunk.nil?

          out << chunk unless chunk.is_a?(Symbol)
        end
        out
      end
    end
  end
end
