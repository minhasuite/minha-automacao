# resto2: TV Android de mentira (Android TV Remote v2) em 127.0.0.1, do lado
# da TV: TLS com certificado próprio pedindo o do cliente; pareamento na
# porta + 1 (mostra o código e confere o segredo) e controle na porta (só
# aceita o certificado pareado; manda estado, ping e recebe teclas e links).
class FakeAndroidTv
  attr_reader :port, :code, :keys, :links, :pong

  def initialize(on: true)
    @on = on
    @keys = []
    @links = []
    pair = AndroidTvRemote.certificate("teste-tv")
    @rsa = OpenSSL::PKey.read(pair["key"])
    @cert = OpenSSL::X509::Certificate.new(pair["cert"])
    control, pairing = ports
    @port = control.addr[1]
    @servers = [ control, pairing ]
    @threads = [ listen(control) { |s| serve_control(s) }, listen(pairing) { |s| serve_pair(s) } ]
  end

  def stop
    @threads.each(&:kill)
    @servers.each(&:close)
  end

  private

  def ports
    loop do
      a = TCPServer.new("127.0.0.1", 0)
      begin
        return [ a, TCPServer.new("127.0.0.1", a.addr[1] + 1) ]
      rescue SystemCallError
        a.close
      end
    end
  end

  def listen(tcp)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.cert = @cert
    ctx.key = @rsa
    ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
    ctx.verify_callback = ->(_ok, _store) { true } # certificado autoassinado do cliente
    server = OpenSSL::SSL::SSLServer.new(tcp, ctx)
    Thread.new do
      loop do
        ssl = server.accept
        Thread.new(ssl) do |s|
          yield s
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, ArgumentError
          nil
        ensure
          s.close rescue nil # rubocop:disable Style/RescueModifier
        end
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        break if tcp.closed?
      end
    end
  end

  def write(s, fields)
    body = Proto.encode(fields)
    s.write(Proto.varint(body.bytesize) + body)
  end

  def read(s)
    len = 0
    shift = 0
    loop do
      b = s.readpartial(1).getbyte(0)
      len |= (b & 0x7F) << shift
      break if b < 0x80

      shift += 7
    end
    body = +"".b
    body << s.readpartial(len - body.bytesize) while body.bytesize < len
    Proto.decode(body)
  rescue EOFError
    nil
  end

  def reply(s, field, body = "", status: 200) = write(s, [ [ 1, :varint, 2 ], [ 2, :enum, status ], [ field, :message, body ] ])

  def serve_pair(s)
    while (m = read(s))
      if m.key?(10) then reply(s, 11, Proto.encode([ [ 1, :string, "Teste TV" ] ]))
      elsif m.key?(20) then reply(s, 20, m[20].first)
      elsif m.key?(30)
        nonce = SecureRandom.hex(2).upcase
        digest = AndroidTvRemote.secret(s.peer_cert.public_key, @cert.public_key, "00#{nonce}")
        @code = format("%02X", digest.getbyte(0)) + nonce
        @secret = digest
        reply(s, 31)
      elsif m.key?(40)
        ok = Proto.decode(m[40].first)[1].first == @secret
        @paired = s.peer_cert.to_der if ok
        ok ? reply(s, 41, Proto.encode([ [ 1, :bytes, @secret ] ])) : reply(s, 41, status: 402)
      end
    end
  end

  def serve_control(s)
    return unless @paired && s.peer_cert&.to_der == @paired # a TV só conversa com quem pareou

    info = Proto.encode([ [ 1, :string, "Teste TV" ], [ 2, :string, "Teste Fabricante" ] ])
    write(s, [ [ 1, :message, Proto.encode([ [ 1, :varint, 622 ], [ 2, :message, info ] ]) ] ])
    read(s) # configuração do cliente
    write(s, [ [ 2, :message, "" ] ])
    read(s) # ativo
    write(s, [ [ 8, :message, Proto.encode([ [ 1, :varint, 7 ] ]) ] ])
    write(s, [ [ 40, :message, Proto.encode([ [ 1, :bool, @on ] ]) ] ])
    write(s, [ [ 50, :message, Proto.encode([ [ 6, :varint, 100 ], [ 7, :varint, 30 ], [ 8, :bool, false ] ]) ] ])
    app = Proto.encode([ [ 12, :string, "com.netflix.ninja" ] ])
    write(s, [ [ 20, :message, Proto.encode([ [ 1, :message, app ] ]) ] ])
    while (m = read(s))
      @pong = Proto.decode(m[9].first)[1].first if m.key?(9)
      @keys << Proto.decode(m[10].first).values_at(1, 2).map(&:first) if m.key?(10)
      @links << Proto.string(Proto.decode(m[90].first)[1].first) if m.key?(90)
    end
  end
end
