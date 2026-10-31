# Broadlink RM de mentira em 127.0.0.1 (porta livre, UDP): hello, auth com a
# troca de chave, enviar, aprender e sensores, como um RM4 Pro (Pacote 1).
class FakeBroadlink
  SESSION = "S" * 16

  attr_reader :port, :sent, :polls

  def initialize(devtype: 0x6026, locked: false, learned: "\x26\x00\x05\x00\x11\x22\x33".b)
    @devtype = devtype
    @locked = locked
    @learned = learned
    @key = Broadlink::KEY
    @sent = []
    @polls = 0
    @sock = UDPSocket.new
    @sock.bind("127.0.0.1", 0)
    @port = @sock.addr[1]
    @thread = Thread.new do
      loop do
        data, from = @sock.recvfrom(4096)
        reply = handle(data)
        @sock.send(reply, 0, from[3], from[1]) if reply
      end
    end
  end

  def stop
    @thread.kill
    @sock.close
  end

  private

  def handle(data)
    type = data.getbyte(0x26)
    return hello if type == 0x06

    return auth(data) if type == 0x65 # auth sempre com a chave de fábrica

    payload = Broadlink.decrypt(@key, data.byteslice(0x38..))

    len, cmd = payload.unpack("vV")
    body = payload.byteslice(6, len - 4)
    case cmd
    when 0x02 then @sent << body
                   reply(data, framed(cmd))
    when 0x03 then @learning = true
                   reply(data, framed(cmd))
    when 0x04
      @polls += 1
      @learning && @polls > 1 ? reply(data, framed(cmd, @learned)) : reply(data, "", err: -5)
    when 0x24 then reply(data, framed(cmd, [ 25, 50, 60, 0 ].pack("c4")))
    end
  end

  def framed(cmd, data = "".b) = [ data.bytesize + 4, cmd ].pack("vV") + data

  def hello
    r = ("\0" * 0x80).b
    r[0x34, 2] = [ @devtype ].pack("v")
    r[0x3a, 6] = [ "a1b2c3d4e5f6" ].pack("H*").reverse
    r[0x40, 10] = "RM da sala"
    r.setbyte(0x7f, @locked ? 1 : 0)
    r
  end

  def auth(data)
    @key = Broadlink::KEY
    resp = reply(data, [ 7 ].pack("V") + SESSION)
    @key = SESSION
    resp
  end

  def reply(req, payload, err: 0)
    r = req.byteslice(0, 0x38).b
    r[0x22, 2] = [ err ].pack("s<")
    r << Broadlink.encrypt(@key, payload.b)
    r[0x20, 2] = "\0\0"
    r[0x20, 2] = [ Broadlink.checksum(r.bytes) ].pack("v")
    r
  end
end
