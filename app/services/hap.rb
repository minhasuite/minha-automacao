require "openssl"
require "socket"
require "json"
require "securerandom"

# HomeKit Accessory Protocol (ondaC1, C5; o homekit_controller do HA), em
# Ruby puro com o OpenSSL: o MA vira "controlador" de acessórios HomeKit da
# rede (Wi-Fi/Ethernet, `_hap._tcp`). Pareamento (pair-setup, SRP-6a 3072
# com SHA-512 e o código de 8 dígitos), verificação a cada conexão
# (pair-verify, X25519 + Ed25519) e a sessão cifrada (ChaCha20-Poly1305 em
# quadros de até 1024 bytes) com o HTTP do HAP: /accessories e
# /characteristics. As chaves do MA e a do acessório ficam nos segredos da
# integração; nada aqui guarda estado.
module Hap
  class Error < StandardError; end

  BASE_UUID = "-0000-1000-8000-0026BB765291".freeze

  # TLV8 do HAP: tipo, tamanho (≤ 255) e valor; valor longo vem em pedaços seguidos.
  module Tlv
    METHOD, IDENTIFIER, SALT, PUBLIC_KEY, PROOF, ENCRYPTED, STATE, ERROR, SIGNATURE = 0, 1, 2, 3, 4, 5, 6, 7, 10

    module_function

    def encode(pairs)
      pairs.map do |type, value|
        v = value.is_a?(Integer) ? [ value ].pack("C") : value.to_s.b
        v.empty? ? [ type, 0 ].pack("CC") : v.bytes.each_slice(255).map { |c| [ type, c.size ].pack("CC") + c.pack("C*") }.join
      end.join.b
    end

    def decode(bin)
      out = {}
      pos = 0
      last = nil
      bin = bin.to_s.b
      while pos + 2 <= bin.bytesize
        type, len = bin.byteslice(pos, 2).unpack("CC")
        value = bin.byteslice(pos + 2, len).to_s
        out[type] = type == last ? out[type] + value : value
        last = type
        pos += 2 + len
      end
      out
    end
  end

  # SRP-6a do HAP (RFC 5054, grupo de 3072 bits, g = 5, SHA-512). N vem do
  # próprio OpenSSL (grupo MODP 3072 do RFC 3526, o mesmo primo).
  module Srp
    N = OpenSSL::PKey.generate_parameters("DH", "group" => "modp_3072").p.to_i
    G = 5
    LEN = 384

    module_function

    def h(*parts) = OpenSSL::Digest::SHA512.digest(parts.join.b)
    def bytes(n) = [ n.to_s(16).rjust(2 * ((n.bit_length + 7) / 8), "0") ].pack("H*")
    def pad(n) = bytes(n).rjust(LEN, "\0".b)
    def int(bin) = bin.unpack1("H*").to_i(16)
    def k = int(h(pad(N), pad(G)))
    def x(salt, user, pass) = int(h(salt, h("#{user}:#{pass}")))
    def u(a_pub, b_pub) = int(h(pad(a_pub), pad(b_pub)))

    def m1(user, salt, a_pub, b_pub, key)
      hn, hg = h(bytes(N)), h(bytes(G))
      h(hn.bytes.zip(hg.bytes).map { |p, q| p ^ q }.pack("C*"), h(user), salt, pad(a_pub), pad(b_pub), key)
    end

    def m2(a_pub, m1, key) = h(pad(a_pub), m1, key)
  end

  module_function

  def hkdf(ikm, salt, info) = OpenSSL::KDF.hkdf(ikm, salt: salt, info: info, length: 32, hash: "SHA512")

  def seal(key, nonce, plain, aad = "".b)
    c = OpenSSL::Cipher.new("chacha20-poly1305").encrypt
    c.key = key
    c.iv = nonce.rjust(12, "\0".b)
    c.auth_data = aad
    c.update(plain) + c.final + c.auth_tag
  end

  def open(key, nonce, sealed, aad = "".b)
    raise Error, "Mensagem cifrada curta demais." if sealed.bytesize < 16

    c = OpenSSL::Cipher.new("chacha20-poly1305").decrypt
    c.key = key
    c.iv = nonce.rjust(12, "\0".b)
    c.auth_tag = sealed.byteslice(-16, 16)
    c.auth_data = aad
    c.update(sealed.byteslice(0...-16)) + c.final
  rescue OpenSSL::Cipher::CipherError
    raise Error, "Não deu para decifrar a resposta do acessório (chave errada?)."
  end

  def ed_private(seed) = OpenSSL::PKey.new_raw_private_key("ED25519", seed)
  def ed_public(raw) = OpenSSL::PKey.new_raw_public_key("ED25519", raw)

  # "aa:bb" / "00000025-0000-1000-8000-0026BB765291" / "25" → "25" (forma curta do HAP).
  def short_type(type)
    t = type.to_s.upcase
    t = t.delete_suffix(BASE_UUID).split("-").first if t.end_with?(BASE_UUID)
    t.sub(/\A0+(?=.)/, "")
  end

  # Conexão com um acessório. `pairing` = {"id", "ltsk" (semente Ed25519 hex),
  # "accessory_id", "accessory_ltpk" (hex)}.
  class Client
    TIMEOUT = 10

    def self.open(host, port, pairing)
      c = new(host, port)
      c.verify!(pairing)
      yield c
    ensure
      c&.close
    end

    def initialize(host, port, sock: nil)
      @host = host
      @port = port.to_i
      @sock = sock
      @buffer = +"".b
    end

    def sock = @sock ||= Socket.tcp(@host, @port, connect_timeout: TIMEOUT)
    def close = @sock&.close

    # Pareia com o código de 8 dígitos → os dados do pareamento (guardar cifrado).
    def pair_setup!(code)
      pin = pin_code(code)
      pair_start!
      pair_finish!(pin)
    end

    def pin_code(code)
      pin = code.to_s.delete("^0-9").sub(/\A(\d{3})(\d{2})(\d{3})\z/, '\1-\2-\3')
      raise Error, "O código de pareamento tem 8 dígitos." unless pin.match?(/\A\d{3}-\d{2}-\d{3}\z/)

      pin
    end

    # M1/M2 do pair-setup (resto2: aparelho com tela, como a Apple TV, mostra o PIN aqui).
    def pair_start!
      m2 = tlv_post("/pair-setup", [ [ Tlv::STATE, 1 ], [ Tlv::METHOD, 0 ] ])
      check!(m2, 2)
      @srp = [ m2[Tlv::SALT], Srp.int(m2[Tlv::PUBLIC_KEY].to_s) ]
      self
    end

    # M3 a M6 com o PIN → os dados do pareamento.
    def pair_finish!(pin)
      salt, b_pub = @srp
      a =SecureRandom.random_number(1 << 256)
      a_pub = Srp::G.pow(a, Srp::N)
      u = Srp.u(a_pub, b_pub)
      x = Srp.x(salt, "Pair-Setup", pin)
      s = ((b_pub - (Srp.k * Srp::G.pow(x, Srp::N))) % Srp::N).pow(a + (u * x), Srp::N)
      key = Srp.h(Srp.pad(s))
      proof = Srp.m1("Pair-Setup", salt, a_pub, b_pub, key)
      m4 = tlv_post("/pair-setup", [ [ Tlv::STATE, 3 ], [ Tlv::PUBLIC_KEY, Srp.pad(a_pub) ], [ Tlv::PROOF, proof ] ])
      check!(m4, 4)
      raise Error, "O acessório não confirmou o código." unless m4[Tlv::PROOF] == Srp.m2(a_pub, proof, key)

      id = SecureRandom.uuid.upcase
      seed = SecureRandom.random_bytes(32)
      ltpk = Hap.ed_private(seed).raw_public_key
      device_x = Hap.hkdf(key, "Pair-Setup-Controller-Sign-Salt", "Pair-Setup-Controller-Sign-Info")
      sig = Hap.ed_private(seed).sign(nil, device_x + id + ltpk)
      enc_key = Hap.hkdf(key, "Pair-Setup-Encrypt-Salt", "Pair-Setup-Encrypt-Info")
      sub = Tlv.encode([ [ Tlv::IDENTIFIER, id ], [ Tlv::PUBLIC_KEY, ltpk ], [ Tlv::SIGNATURE, sig ] ])
      m6 = tlv_post("/pair-setup", [ [ Tlv::STATE, 5 ], [ Tlv::ENCRYPTED, Hap.seal(enc_key, "PS-Msg05", sub) ] ])
      check!(m6, 6)
      info = Tlv.decode(Hap.open(enc_key, "PS-Msg06", m6[Tlv::ENCRYPTED].to_s))
      acc_x = Hap.hkdf(key, "Pair-Setup-Accessory-Sign-Salt", "Pair-Setup-Accessory-Sign-Info")
      acc_id, acc_ltpk = info[Tlv::IDENTIFIER], info[Tlv::PUBLIC_KEY]
      raise Error, "Assinatura do acessório não confere." unless Hap.ed_public(acc_ltpk).verify(nil, info[Tlv::SIGNATURE], acc_x + acc_id + acc_ltpk)

      { "id" => id, "ltsk" => seed.unpack1("H*"), "accessory_id" => acc_id, "accessory_ltpk" => acc_ltpk.unpack1("H*") }
    end

    # Pair-verify: confere o acessório pelo pareamento guardado e liga a sessão cifrada.
    def verify!(pairing)
      mine = OpenSSL::PKey.generate_key("X25519")
      m2 = tlv_post("/pair-verify", [ [ Tlv::STATE, 1 ], [ Tlv::PUBLIC_KEY, mine.raw_public_key ] ])
      check!(m2, 2)
      theirs = m2[Tlv::PUBLIC_KEY].to_s
      shared = mine.derive(OpenSSL::PKey.new_raw_public_key("X25519", theirs))
      key = Hap.hkdf(shared, "Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info")
      info = Tlv.decode(Hap.open(key, "PV-Msg02", m2[Tlv::ENCRYPTED].to_s))
      unless info[Tlv::IDENTIFIER] == pairing["accessory_id"] &&
             Hap.ed_public([ pairing["accessory_ltpk"] ].pack("H*")).verify(nil, info[Tlv::SIGNATURE].to_s, theirs + info[Tlv::IDENTIFIER] + mine.raw_public_key)
        raise Error, "O acessório não é o que foi pareado (pareie de novo)."
      end

      sig = Hap.ed_private([ pairing["ltsk"] ].pack("H*")).sign(nil, mine.raw_public_key + pairing["id"] + theirs)
      sub = Tlv.encode([ [ Tlv::IDENTIFIER, pairing["id"] ], [ Tlv::SIGNATURE, sig ] ])
      check!(tlv_post("/pair-verify", [ [ Tlv::STATE, 3 ], [ Tlv::ENCRYPTED, Hap.seal(key, "PV-Msg03", sub) ] ]), 4)
      session_keys!(shared)
      @out = @in = 0
      self
    end

    def session_keys!(shared)
      @write = Hap.hkdf(shared, "Control-Salt", "Control-Write-Encryption-Key")
      @read = Hap.hkdf(shared, "Control-Salt", "Control-Read-Encryption-Key")
    end

    def accessories = Array(json(request("GET", "/accessories"))["accessories"])
    def characteristics(ids) = Array(json(request("GET", "/characteristics?id=#{ids.join(',')}"))["characteristics"])
    def put(list) = request("PUT", "/characteristics", { "characteristics" => list }.to_json, "application/hap+json")

    # HTTP do HAP (às claras antes da verificação, cifrado depois) → [status, corpo].
    def request(method, path, body = nil, type = nil)
      head = "#{method} #{path} HTTP/1.1\r\nHost: #{@host}:#{@port}\r\n"
      head += "Content-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n" if body
      write("#{head}\r\n".b + body.to_s.b)
      status, raw = read_response
      raise Error, "Acessório respondeu #{status} em #{path}." unless status.between?(200, 299)

      raw
    end

    private

    def tlv_post(path, pairs) = Tlv.decode(request("POST", path, Tlv.encode(pairs), "application/pairing+tlv8"))

    def check!(tlv, state)
      raise Error, "Acessório recusou (erro #{tlv[Tlv::ERROR].unpack1('C')}: #{ERRORS.fetch(tlv[Tlv::ERROR].unpack1('C'), '?')})." if tlv[Tlv::ERROR]
      raise Error, "Resposta fora de ordem do acessório." unless tlv[Tlv::STATE]&.unpack1("C") == state
    end

    ERRORS = { 1 => "falha", 2 => "código errado", 3 => "tentativas demais", 4 => "desconhecido", 5 => "lista cheia", 6 => "já pareado com outro controlador", 7 => "ocupado" }.freeze

    def json(raw) = JSON.parse(raw.to_s.empty? ? "{}" : raw)

    def write(data)
      return sock.write(data) unless @write

      data.bytes.each_slice(1024) do |chunk|
        plain = chunk.pack("C*")
        aad = [ plain.bytesize ].pack("v")
        sock.write(aad + Hap.seal(@write, [ @out ].pack("Q<"), plain, aad))
        @out += 1
      end
    end

    def fill
      raise Error, "O acessório não respondeu em #{TIMEOUT} s." unless sock.wait_readable(TIMEOUT)

      chunk = sock.readpartial(65_536)
      return @buffer << chunk unless @read

      @raw = (@raw || +"".b) << chunk
      while @raw.bytesize >= 2 && @raw.bytesize >= 2 + (len = @raw.unpack1("v")) + 16
        aad = @raw.byteslice(0, 2)
        @buffer << Hap.open(@read, [ @in ].pack("Q<"), @raw.byteslice(2, len + 16), aad)
        @in += 1
        @raw = @raw.byteslice((2 + len + 16)..).to_s
      end
    rescue EOFError
      raise Error, "O acessório fechou a conexão."
    end

    def read_response
      fill until (i = @buffer.index("\r\n\r\n"))
      head = @buffer.byteslice(0, i)
      @buffer = @buffer.byteslice((i + 4)..).to_s
      status = head[/\A(?:HTTP|EVENT)\/1\.\d (\d{3})/, 1].to_i
      return [ status, chunked ] if head.match?(/^Transfer-Encoding:\s*chunked/i)

      len = head[/^Content-Length:\s*(\d+)/i, 1].to_i
      [ status, take(len) ]
    end

    def take(len)
      fill while @buffer.bytesize < len
      @buffer.byteslice(0, len).tap { @buffer = @buffer.byteslice(len..).to_s }
    end

    # Corpo em pedaços (o hap-nodejs responde assim): tamanho em hex, CRLF,
    # dados, CRLF… e o pedaço vazio no fim.
    def chunked
      body = +"".b
      loop do
        fill until (i = @buffer.index("\r\n"))
        size = @buffer.byteslice(0, i).to_i(16)
        @buffer = @buffer.byteslice((i + 2)..).to_s
        body << take(size)
        take(2)
        return body if size.zero?
      end
    end
  end
end
