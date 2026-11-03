# ondaC1 (C5): acessório HomeKit de mentira em 127.0.0.1, do lado do
# acessório do HAP (SRP-6a, pair-verify, sessão cifrada), para o Hap::Client
# falar de verdade por TCP. Uma lâmpada (On, Brightness) e um sensor de
# temperatura numa ponte de 2 acessórios. O /accessories responde em pedaços
# (chunked), como o hap-nodejs. O cliente também foi conferido contra o
# hap-nodejs real (ver o README da ondaC1).
class FakeHapAccessory
  ID = "1A:2B:3C:4D:5E:6F".freeze
  attr_reader :port, :values, :puts

  def initialize(pin: "031-45-154")
    @pin = pin
    @seed = SecureRandom.random_bytes(32)
    @values = { [ 1, 10 ] => false, [ 1, 11 ] => 40, [ 2, 10 ] => 21.5 }
    @puts = []
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { loop { serve(@server.accept) } }
  end

  def stop
    @thread.kill
    @server.close
  end

  def accessories
    info = ->(name) { { "type" => "3E", "iid" => 1, "characteristics" => [ { "type" => "23", "iid" => 2, "value" => name, "perms" => [ "pr" ] }, { "type" => "20", "iid" => 3, "value" => "Teste Fabricante", "perms" => [ "pr" ] } ] } }
    { "accessories" => [
      { "aid" => 1, "services" => [ info.call("Teste Lâmpada"), { "type" => "00000043-0000-1000-8000-0026BB765291", "iid" => 9, "characteristics" => [
        { "type" => "00000025-0000-1000-8000-0026BB765291", "iid" => 10, "value" => @values[[ 1, 10 ]], "perms" => %w[pr pw ev], "format" => "bool" },
        { "type" => "8", "iid" => 11, "value" => @values[[ 1, 11 ]], "perms" => %w[pr pw ev], "format" => "int", "minValue" => 0, "maxValue" => 100 } ] } ] },
      { "aid" => 2, "services" => [ info.call("Teste Sensor"), { "type" => "8A", "iid" => 9, "characteristics" => [
        { "type" => "11", "iid" => 10, "value" => @values[[ 2, 10 ]], "perms" => %w[pr ev], "format" => "float" } ] } ] }
    ] }
  end

  private

  def serve(sock)
    @sock, @buf, @read_key, @write_key = sock, +"".b, nil, nil
    loop do
      req = request or break
      method, path, body = req
      case path
      when "/pair-setup" then reply(pair_setup(Hap::Tlv.decode(body)), "application/pairing+tlv8")
      when "/pair-verify" then reply(pair_verify(Hap::Tlv.decode(body)), "application/pairing+tlv8")
      when "/accessories" then reply(accessories.to_json, "application/hap+json", chunked: true)
      when %r{\A/characteristics}
        if method == "PUT"
          JSON.parse(body)["characteristics"].each { |c| @puts << c && @values[[ c["aid"], c["iid"] ]] = c["value"] }
          reply("", nil, status: 204)
        else
          ids = path[/id=([\d.,]+)/, 1].split(",").map { |x| x.split(".").map(&:to_i) }
          reply({ "characteristics" => ids.map { |a, i| { "aid" => a, "iid" => i, "value" => @values[[ a, i ]] } } }.to_json, "application/hap+json")
        end
      end
    end
  rescue IOError, SystemCallError, Hap::Error
    nil
  ensure
    sock.close
  end

  def pair_setup(t)
    s = Hap::Srp
    case t[Hap::Tlv::STATE].unpack1("C")
    when 1
      @salt = SecureRandom.random_bytes(16)
      @v = s::G.pow(s.x(@salt, "Pair-Setup", @pin), s::N)
      @b = SecureRandom.random_number(1 << 256)
      @b_pub = ((s.k * @v) + s::G.pow(@b, s::N)) % s::N
      Hap::Tlv.encode([ [ 6, 2 ], [ 2, @salt ], [ 3, s.pad(@b_pub) ] ])
    when 3
      a_pub = s.int(t[3])
      sh = (a_pub * @v.pow(s.u(a_pub, @b_pub), s::N)).pow(@b, s::N)
      @key = s.h(s.pad(sh))
      return Hap::Tlv.encode([ [ 6, 4 ], [ 7, 2 ] ]) unless t[4] == s.m1("Pair-Setup", @salt, a_pub, @b_pub, @key)

      Hap::Tlv.encode([ [ 6, 4 ], [ 4, s.m2(a_pub, t[4], @key) ] ])
    when 5
      enc = Hap.hkdf(@key, "Pair-Setup-Encrypt-Salt", "Pair-Setup-Encrypt-Info")
      sub = Hap::Tlv.decode(Hap.open(enc, "PS-Msg05", t[5]))
      x = Hap.hkdf(@key, "Pair-Setup-Controller-Sign-Salt", "Pair-Setup-Controller-Sign-Info")
      return Hap::Tlv.encode([ [ 6, 6 ], [ 7, 2 ] ]) unless Hap.ed_public(sub[3]).verify(nil, sub[10], x + sub[1] + sub[3])

      @controller = [ sub[1], sub[3] ]
      ltpk = Hap.ed_private(@seed).raw_public_key
      ax = Hap.hkdf(@key, "Pair-Setup-Accessory-Sign-Salt", "Pair-Setup-Accessory-Sign-Info")
      info = Hap::Tlv.encode([ [ 1, ID ], [ 3, ltpk ], [ 10, Hap.ed_private(@seed).sign(nil, ax + ID + ltpk) ] ])
      Hap::Tlv.encode([ [ 6, 6 ], [ 5, Hap.seal(enc, "PS-Msg06", info) ] ])
    end
  end

  def pair_verify(t)
    case t[Hap::Tlv::STATE].unpack1("C")
    when 1
      mine = OpenSSL::PKey.generate_key("X25519")
      @their_curve = t[3]
      @curve = mine.raw_public_key
      @shared = mine.derive(OpenSSL::PKey.new_raw_public_key("X25519", @their_curve))
      @vkey = Hap.hkdf(@shared, "Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info")
      sub = Hap::Tlv.encode([ [ 1, ID ], [ 10, Hap.ed_private(@seed).sign(nil, @curve + ID + @their_curve) ] ])
      Hap::Tlv.encode([ [ 6, 2 ], [ 3, @curve ], [ 5, Hap.seal(@vkey, "PV-Msg02", sub) ] ])
    when 3
      sub = Hap::Tlv.decode(Hap.open(@vkey, "PV-Msg03", t[5]))
      ok = @controller && sub[1] == @controller[0] && Hap.ed_public(@controller[1]).verify(nil, sub[10], @their_curve + sub[1] + @curve)
      return Hap::Tlv.encode([ [ 6, 4 ], [ 7, 2 ] ]) unless ok

      @pending = [ Hap.hkdf(@shared, "Control-Salt", "Control-Write-Encryption-Key"), Hap.hkdf(@shared, "Control-Salt", "Control-Read-Encryption-Key") ]
      Hap::Tlv.encode([ [ 6, 4 ] ])
    end
  end

  # --- HTTP (às claras e depois cifrado) ---------------------------------------
  def request
    fill until (i = @buf.index("\r\n\r\n"))
    head = @buf.byteslice(0, i)
    @buf = @buf.byteslice((i + 4)..).to_s
    method, path = head.split(" ", 3)
    len = head[/^Content-Length:\s*(\d+)/i, 1].to_i
    fill while @buf.bytesize < len
    body = @buf.byteslice(0, len)
    @buf = @buf.byteslice(len..).to_s
    [ method, path, body ]
  rescue EOFError
    nil
  end

  def fill
    chunk = @sock.readpartial(65_536)
    return @buf << chunk unless @read_key

    @raw = (@raw || +"".b) << chunk
    while @raw.bytesize >= 18 && @raw.bytesize >= 18 + (len = @raw.unpack1("v"))
      @buf << Hap.open(@read_key, [ @in ].pack("Q<"), @raw.byteslice(2, len + 16), @raw.byteslice(0, 2))
      @in += 1
      @raw = @raw.byteslice((len + 18)..).to_s
    end
  end

  def reply(body, type, status: 200, chunked: false)
    head = "HTTP/1.1 #{status} OK\r\n#{"Content-Type: #{type}\r\n" if type}"
    data = chunked ? "#{head}Transfer-Encoding: chunked\r\n\r\n#{body.bytesize.to_s(16)}\r\n#{body}\r\n0\r\n\r\n" : "#{head}Content-Length: #{body.bytesize}\r\n\r\n#{body}"
    send_out(data.b)
    return unless @pending

    @read_key, @write_key = @pending # o acessório lê com a chave de escrita do controlador
    @pending = nil
    @in = @out = 0
    @raw = +"".b
  end

  def send_out(data)
    return @sock.write(data) unless @write_key

    data.bytes.each_slice(1024) do |c|
      plain = c.pack("C*")
      aad = [ plain.bytesize ].pack("v")
      @sock.write(aad + Hap.seal(@write_key, [ @out ].pack("Q<"), plain, aad))
      @out += 1
    end
  end
end
