require "socket"

# Ao vivo fora de casa (cameras2): o MSE do go2rtc (`/api/ws?src=`) passa pelo Rails.
# O controller confere sessão, papel, origem e a vaga (`Cameras::Streams`), toma a
# conexão do Puma (Rack hijack, a thread do Puma volta na hora) e esta classe abre o
# WebSocket no go2rtc com a mesma `Sec-WebSocket-Key` do navegador (a resposta 101 do
# go2rtc vale para ele) e depois só copia bytes nos dois sentidos, numa thread própria.
#
# Túnel: o vídeo não para de passar (sem tempo ocioso no proxy reverso); conexão sem
# nenhum byte por IDLE_S fecha, e nenhuma passa de MAX_S (o navegador abre de novo).
module Cameras
  class WsProxy
    IDLE_S = 30
    MAX_S = 30 * 60
    TOUCH_S = 20
    HEAD_MAX = 8.kilobytes
    CHUNK = 64.kilobytes

    def self.start(client, target, ws_key, on_touch: nil, on_close: nil)
      proxy = new(client, target, ws_key, on_touch:, on_close:)
      Thread.new { proxy.run }.tap { |t| t.name = "camera-ws" }
    end

    def initialize(client, target, ws_key, on_touch: nil, on_close: nil)
      @client, @target, @ws_key, @on_touch, @on_close = client, URI(target), ws_key, on_touch, on_close
    end

    def run
      upstream = Socket.tcp(@target.host, @target.port, connect_timeout: 3)
      upstream.write(handshake)
      head = read_head(upstream)
      unless head&.start_with?("HTTP/1.1 101")
        @client.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        return
      end
      @client.write(head)
      pipe(upstream)
    rescue SystemCallError, IOError, SocketError => e
      Rails.logger.info("[camera-ws] #{e.class.name.demodulize}")
      begin
        @client.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") unless @upgraded
      rescue SystemCallError, IOError
        nil
      end
    ensure
      [ upstream, @client ].each { |io| io&.close rescue nil } # rubocop:disable Style/RescueModifier
      @on_close&.call
    end

    private

    # Sem Origin (o go2rtc aceita sem) e sem extensões (nada de compressão no meio).
    def handshake
      "GET #{@target.request_uri} HTTP/1.1\r\nHost: #{@target.host}:#{@target.port}\r\nUpgrade: websocket\r\n" \
        "Connection: Upgrade\r\nSec-WebSocket-Key: #{@ws_key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    end

    # Cabeçalho da resposta do go2rtc, byte a byte até a linha em branco (nada de vídeo
    # fica preso num buffer de leitura antes do IO.select).
    def read_head(io)
      buf = +""
      deadline = monotonic + 5
      until buf.end_with?("\r\n\r\n")
        return nil if buf.bytesize > HEAD_MAX || monotonic > deadline

        ready = io.wait_readable(deadline - monotonic) or return nil
        byte = ready.read_nonblock(1, exception: false)
        return nil if byte.nil?
        next if byte == :wait_readable

        buf << byte
      end
      @upgraded = true
      buf
    end

    def pipe(upstream)
      started = last_data = last_touch = monotonic
      peers = { @client => upstream, upstream => @client }
      loop do
        now = monotonic
        break if now - started > MAX_S || now - last_data > IDLE_S

        if now - last_touch > TOUCH_S
          @on_touch&.call
          last_touch = now
        end
        readable, = IO.select(peers.keys, nil, nil, 1)
        next unless readable

        readable.each do |io|
          data = io.read_nonblock(CHUNK, exception: false)
          return if data.nil? # o outro lado fechou
          next if data == :wait_readable

          peers[io].write(data)
          last_data = monotonic
        end
      end
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
