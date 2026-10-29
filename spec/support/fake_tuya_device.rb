# Aparelho Tuya de mentira em 127.0.0.1 (porta livre): negocia a sessão,
# responde ao pedido de estado, aplica CONTROL e empurra o status, como um
# aparelho real. `push(dps)` simula o botão físico.
class FakeTuyaDevice
  KEY = "0123456789abcdef".freeze

  attr_reader :port, :state, :received

  def initialize(version: "3.5", state: { "1" => false, "19" => 1234 })
    @version = version
    @state = state
    @received = Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve }
  end

  def push(dps)
    @state.merge!(dps)
    send_msg(8, status_json(dps))
  end

  def disconnect = @client&.close

  def stop
    @thread.kill
    @client&.close
    @server.close
  end

  private

  def serve
    loop do
      @client = @server.accept
      @proto = Tuya::Protocol.new(@version, KEY)
      @seq = 100
      buffer = "".b
      loop do
        chunk = @client.readpartial(4096)
        buffer << chunk
        while (msg, rest = @proto.unpack(buffer))
          buffer = rest
          handle(msg)
        end
      end
    rescue EOFError, IOError, Errno::ECONNRESET
      next
    end
  end

  def handle(msg)
    @received << msg.cmd
    case msg.cmd
    when 3
      remote = "R" * 16
      resp = remote + OpenSSL::HMAC.digest("SHA256", KEY, msg.payload)
      send_msg(4, resp)
      @session = Tuya::Protocol.new(@version, KEY).tap { |p| p.session_finish(msg.payload, resp) }.key
    when 5 then @proto.key = @session
    when 10, 16 then send_msg(msg.cmd, JSON.generate({ dps: @state }))
    when 9 then send_msg(9, "")
    when 7, 13
      dps = msg.dps || {}
      @state.merge!(dps)
      send_msg(msg.cmd, "")
      send_msg(8, status_json(dps))
    end
  end

  def status_json(dps) = JSON.generate({ protocol: 4, t: 1, data: { dps: dps } })

  # Resposta do aparelho: no 55AA o código de retorno vai antes do payload.
  def send_msg(cmd, payload)
    @seq += 1
    frame = @proto.pack(@seq, cmd, payload)
    if @version != "3.5" && !payload.empty?
      # reconstrói com o código de retorno (0) na frente do payload cifrado
      body = frame.byteslice(16, frame.unpack("N4")[3] - (@version == "3.4" ? 36 : 8))
      frame = rebuild_55aa(cmd, [ 0 ].pack("N") + body)
    end
    @client.write(frame)
  end

  def rebuild_55aa(cmd, payload)
    hmac = @version == "3.4"
    header = [ 0x55AA, @seq, cmd, payload.bytesize + (hmac ? 32 : 4) + 4 ].pack("N4")
    check = hmac ? OpenSSL::HMAC.digest("SHA256", @proto.key, header + payload) : [ Zlib.crc32(header + payload) ].pack("N")
    header + payload + check + [ 0xAA55 ].pack("N")
  end
end
