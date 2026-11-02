require "socket"
require "openssl"

# Midea (integ2): protocolo local dos ACs Midea e das marcas do grupo
# (Springer Midea, Comfee, Carrier…), o mesmo do msmart-ng que o HA usa.
# TCP 6444, versão 3: aperto de mão com o token (64 bytes) e a chave
# (32 bytes) do aparelho → chave da sessão; cada pedido vai num envelope
# 0x8370 (AES-CBC + SHA-256) com o pacote 0x5A5A (AES-ECB + MD5) e, dentro, o
# quadro 0xAA do AC. Token e chave saem uma vez da nuvem (ex.: `msmart-ng
# discover`) e ficam cifrados na integração.
module Midea
  class Error < StandardError; end

  PORT = 6444
  SIGN_KEY = "xhdiwjnchekd4d512chdjx5d8e4c394D2D7S".b.freeze
  ENC_KEY = Digest::MD5.digest(SIGN_KEY).freeze
  HANDSHAKE, ENCRYPTED_RESPONSE, ENCRYPTED_REQUEST = 0, 3, 6
  QUERY = [ 0x41, 0x81, 0x00, 0xFF, 0x03, 0xFF, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 ].pack("C*").freeze

  module_function

  def aes(mode, key, data, encrypt:, pad: false)
    c = OpenSSL::Cipher.new("aes-#{key.bytesize * 8}-#{mode}")
    encrypt ? c.encrypt : c.decrypt
    c.key = key
    c.iv = "\0".b * 16 if mode == "cbc"
    c.padding = pad ? 1 : 0
    c.update(data) + c.final
  end

  def xor(a, b) = a.bytes.zip(b.bytes).map { |x, y| x ^ y }.pack("C*")
  def sum8(bytes) = (~bytes.sum + 1) & 0xFF

  # CRC-8 Dallas/Maxim (refletido, 0x8C), o do corpo dos comandos do AC.
  def crc8(bytes)
    bytes.reduce(0) do |crc, b|
      crc ^= b
      8.times { crc = crc.odd? ? (crc >> 1) ^ 0x8C : crc >> 1 }
      crc
    end
  end

  # Quadro 0xAA do AC (tipo 0x03 consulta, 0x02 grava): cabeçalho de 10 bytes, corpo + id + CRC, soma.
  def frame(type, body, id: 1)
    body = body.bytes + [ id ]
    body << crc8(body)
    f = [ 0xAA, 10 + body.size, 0xAC, 0, 0, 0, 0, 0, 0x03, type ] + body
    (f << sum8(f[1..])).pack("C*")
  end

  # Corpo do quadro de resposta (sem cabeçalho e soma).
  def body(frame)
    raise Error, "Resposta do AC fora do formato." unless frame.getbyte(0) == 0xAA && frame.bytesize > 11

    frame.byteslice(10, frame.bytesize - 11)
  end

  # Pacote 0x5A5A: cabeçalho de 40 bytes (id do aparelho em 20..27), quadro cifrado, MD5.
  def packet(device_id, frame, at: Time.now)
    stamp = at.strftime("%Y%m%d%H%M%S%L")[0, 16].scan(/../).map(&:to_i).reverse.pack("C*")
    head = [ 0x5A, 0x5A, 0x01, 0x11, 0, 0, 0x20, 0x00 ].pack("C*") + ("\0".b * 4) + stamp + [ device_id.to_i ].pack("Q<") + ("\0".b * 12)
    data = head + aes("ecb", ENC_KEY, frame, encrypt: true, pad: true)
    data[4, 2] = [ data.bytesize + 16 ].pack("v")
    data + Digest::MD5.digest(data + SIGN_KEY)
  end

  def unpacket(data)
    raise Error, "Pacote do AC fora do formato." unless data.byteslice(0, 2) == "\x5A\x5A".b && data.bytesize > 56

    aes("ecb", ENC_KEY, data.byteslice(40, data.bytesize - 56), encrypt: false, pad: true)
  end

  # Estado do AC (resposta 0xC0) → campos crus do aparelho.
  def state(body)
    p = body.bytes
    raise Error, "Resposta do AC não é de estado." unless p[0] == 0xC0

    { power: p[1].anybits?(0x01), mode: (p[2] >> 5) & 0x07, target: (p[2] & 0x0F) + 16 + (p[2].anybits?(0x10) ? 0.5 : 0), fan: p[3] & 0x7F,
      current: (p[11] == 0xFF ? nil : (p[11] - 50) / 2.0) }
  end

  # Comando 0x40 com o estado inteiro (o AC não aceita só um campo).
  def set_body(power:, mode:, target:, fan:)
    t = target.to_f.clamp(16, 30)
    temp = ((mode.to_i & 0x07) << 5) | ((t.floor - 16) & 0x0F) | (t % 1 >= 0.5 ? 0x10 : 0)
    ([ 0x40, 0x42 | (power ? 1 : 0), temp, fan.to_i & 0x7F, 0x7F, 0x7F, 0x00, 0x30 ] + ([ 0 ] * 15)).pack("C*")
  end

  # Envelope 0x8370 com a chave da sessão (dos dois lados: o aparelho falso do spec usa o mesmo).
  class Codec
    attr_accessor :key

    def initialize(key = nil)
      @key = key
      @count = 0
    end

    def encode(data, type)
      data = data.b
      size = data.bytesize
      pad = 0
      secret = [ ENCRYPTED_REQUEST, ENCRYPTED_RESPONSE ].include?(type)
      if secret
        pad = (16 - ((size + 2) % 16)) % 16
        data += Random.bytes(pad)
        size += pad + 32
      end
      head = [ 0x83, 0x70, size, 0x20, (pad << 4) | type ].pack("CCnCC")
      data = [ @count ].pack("n") + data
      @count = (@count + 1) & 0xFFFF
      return head + data unless secret # aperto de mão: às claras

      head + Midea.aes("cbc", @key, data, encrypt: true) + Digest::SHA256.digest(head + data)
    end

    def decode(raw)
      head = raw.byteslice(0, 6)
      raise Error, "Envelope do AC fora do formato." unless head.byteslice(0, 2) == "\x83\x70".b

      pad = head.getbyte(5) >> 4
      data = raw.byteslice(6..)
      return data.byteslice(2..) unless [ ENCRYPTED_REQUEST, ENCRYPTED_RESPONSE ].include?(head.getbyte(5) & 0x0F)

      sign = data.byteslice(-32, 32)
      data = Midea.aes("cbc", @key, data.byteslice(0, data.bytesize - 32), encrypt: false)
      raise Error, "Assinatura do AC não confere." unless Digest::SHA256.digest(head + data) == sign

      data = data.byteslice(0, data.bytesize - pad)
      data.byteslice(2..)
    end

    # Lê um envelope inteiro do socket.
    def self.read(sock, timeout)
      head = read_exact(sock, 6, timeout)
      raise Error, "Token ou chave recusados pelo AC." if head.start_with?("ERROR")

      head + read_exact(sock, head.byteslice(2, 2).unpack1("n") + 2, timeout)
    end

    def self.read_exact(sock, n, timeout)
      out = +"".b
      while out.bytesize < n
        raise Error, "O AC não respondeu." unless IO.select([ sock ], nil, nil, timeout)

        chunk = sock.read_nonblock(n - out.bytesize, exception: false)
        raise Error, "O AC fechou a conexão." if chunk.nil?

        out << chunk unless chunk.is_a?(Symbol)
      end
      out
    end
  end

  # Uma conexão: aperto de mão e pedidos (quadro AA → quadro AA de resposta).
  class Session
    def self.open(host:, device_id:, token:, key:, port: PORT, timeout: 5)
      s = new(host, port, device_id, token, key, timeout).connect
      yield s
    ensure
      s&.close
    end

    def initialize(host, port, device_id, token, key, timeout)
      @host, @port, @device_id, @timeout = host, port.to_i.positive? ? port.to_i : PORT, device_id, timeout
      @token = [ token.to_s ].pack("H*")
      @key = [ key.to_s ].pack("H*")
      raise Integrations.auth(Error.new("Token (128 hex) ou chave (64 hex) do AC inválidos.")) unless @token.bytesize == 64 && @key.bytesize == 32

      @codec = Codec.new
    end

    def connect
      @sock = Socket.tcp(@host, @port, connect_timeout: @timeout)
      @sock.write(@codec.encode(@token, HANDSHAKE))
      res = Codec.read(@sock, @timeout).byteslice(8, 64)
      raise Integrations.auth(Error.new("O AC recusou o token.")) unless res&.bytesize == 64

      plain = Midea.aes("cbc", @key, res.byteslice(0, 32), encrypt: false)
      raise Integrations.auth(Error.new("Chave do AC não confere.")) unless Digest::SHA256.digest(plain) == res.byteslice(32, 32)

      @codec.key = Midea.xor(plain, @key)
      self
    rescue SystemCallError, SocketError, IOError => e
      close
      raise Error, "Sem conexão com #{@host}:#{@port} (#{e.class.name.demodulize})."
    end

    def request(frame)
      @sock.write(@codec.encode(Midea.packet(@device_id, frame), ENCRYPTED_REQUEST))
      Midea.unpacket(@codec.decode(Codec.read(@sock, @timeout)))
    end

    def state = Midea.state(Midea.body(request(Midea.frame(0x03, QUERY))))
    def set(**) = request(Midea.frame(0x02, Midea.set_body(**)))

    def close
      @sock&.close
    rescue IOError
      nil
    ensure
      @sock = nil
    end
  end
end
