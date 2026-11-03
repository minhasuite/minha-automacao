require "openssl"
require "socket"

# resto2 (grupo 9 #16; o `androidtv_remote` do HA): protocolo Android TV
# Remote v2, o mesmo do controle do app Google TV no celular. Protobuf
# (`Proto`) com o tamanho em varint na frente, sobre TLS com o certificado
# do próprio MA (gerado uma vez e guardado cifrado na integração; a TV lembra
# dele depois do pareamento).
# - Pareamento (porta 6467): pedido → opções (código hex de 6) →
#   configuração; a TV mostra o código; o segredo é o SHA-256 do módulo e do
#   expoente das duas chaves públicas + os 4 últimos caracteres do código (o
#   1º byte do hash tem de bater com os 2 primeiros).
# - Controle (porta 6466): a TV manda a configuração, o MA responde, ativa e
#   recebe ligada/desligada, volume e o app aberto; tecla = `remote_key_inject`.
module AndroidTvRemote
  Error = Class.new(StandardError)
  TIMEOUT = 5
  FEATURES = 622 # ping, tecla, ligar, volume e abrir app (o que o app do Google anuncia)
  KEYS = { "power" => 26, "wake" => 224, "sleep" => 223, "home" => 3, "back" => 4, "up" => 19, "down" => 20, "left" => 21, "right" => 22, "center" => 23,
           "volume_up" => 24, "volume_down" => 25, "mute" => 164, "play_pause" => 85, "resume" => 126, "pause" => 127, "next" => 87, "previous" => 88,
           "menu" => 82, "guide" => 172, "channel_up" => 166, "channel_down" => 167, "settings" => 176, "input" => 178 }.freeze

  module_function

  # Par de chave e certificado do MA (autoassinado, 10 anos).
  def certificate(name = "minha-automacao")
    key = OpenSSL::PKey::RSA.new(2048)
    c = OpenSSL::X509::Certificate.new
    c.version = 2
    c.serial = SecureRandom.random_number(1 << 63)
    c.subject = c.issuer = OpenSSL::X509::Name.parse("/CN=#{name}")
    c.public_key = key.public_key
    c.not_before = Time.now - 86_400
    c.not_after = Time.now + (3650 * 86_400)
    c.sign(key, OpenSSL::Digest.new("SHA256"))
    { "key" => key.to_pem, "cert" => c.to_pem }
  end

  # Inteiro → bytes big-endian (o `bytes.fromhex(f"{n:X}")` do androidtvremote2).
  def bin(n)
    hex = n.to_i.to_s(16)
    [ hex.size.odd? ? "0#{hex}" : hex ].pack("H*")
  end

  # Hash do segredo do pareamento (o mesmo dos dois lados).
  def secret(client_key, server_key, code)
    parts = [ client_key.n, client_key.e, server_key.n, server_key.e ].map { |n| bin(n) }
    OpenSSL::Digest::SHA256.digest(parts.join + [ code.to_s[2..] ].pack("H*"))
  end

  # Conexão TLS com mensagens protobuf de tamanho prefixado. A TV usa
  # certificado próprio sem cadeia: quem garante a ponta é o pareamento.
  class Conn
    attr_reader :ssl

    def initialize(host, port, pair)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.key = OpenSSL::PKey.read(pair["key"].to_s)
      ctx.cert = OpenSSL::X509::Certificate.new(pair["cert"].to_s)
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
      @ssl = OpenSSL::SSL::SSLSocket.new(Socket.tcp(host, port.to_i, connect_timeout: TIMEOUT), ctx).tap { |s| s.sync_close = true }
      @ssl.connect
      @buf = +"".b
    rescue OpenSSL::SSL::SSLError => e
      @ssl&.close
      raise Error, "TLS: #{e.message.truncate(80)}"
    end

    def send_msg(fields)
      body = Proto.encode(fields)
      @ssl.write(Proto.varint(body.bytesize) + body)
    end

    # Próxima mensagem decodificada, ou nil se nada chegar em `timeout` s.
    def read_msg(timeout = TIMEOUT)
      loop do
        if (msg = take)
          return msg
        end
        return nil unless @ssl.pending.positive? || @ssl.wait_readable(timeout)

        @buf << @ssl.readpartial(65_536)
      end
    rescue EOFError
      raise Error, "a TV fechou a conexão"
    end

    def close = @ssl&.close

    private

    def take
      return if @buf.empty?

      len, pos = Proto.read_varint(@buf, 0)
      return if @buf.bytesize < pos + len

      msg = @buf.byteslice(pos, len)
      @buf = @buf.byteslice((pos + len)..).to_s
      Proto.decode(msg)
    rescue ArgumentError # varint ainda incompleto
      nil
    end
  end

  # Pareamento: abre e deixa a TV mostrando o código; `finish!` manda o segredo.
  class Pairing
    def initialize(host, port, pair)
      @pair = pair
      @conn = Conn.new(host, port, pair)
      encoding = Proto.encode([ [ 1, :enum, 3 ], [ 2, :varint, 6 ] ]) # hexadecimal, 6 símbolos
      ask(10, Proto.encode([ [ 1, :string, "atvremote" ], [ 2, :string, "Minha Automação" ] ]), 11)
      ask(20, Proto.encode([ [ 1, :message, encoding ], [ 3, :enum, 1 ] ]), 20) # papel: quem digita
      ask(30, Proto.encode([ [ 1, :message, encoding ], [ 2, :enum, 1 ] ]), 31)
    rescue StandardError
      close
      raise
    end

    # true = pareado; false = código não confere (a conexão segue aberta para tentar de novo).
    def finish!(code)
      code = code.to_s.upcase.delete("^0-9A-F")
      return false unless code.size == 6

      digest = AndroidTvRemote.secret(OpenSSL::X509::Certificate.new(@pair["cert"]).public_key, @conn.ssl.peer_cert.public_key, code)
      return false unless digest.getbyte(0) == code[0, 2].to_i(16)

      ask(40, Proto.encode([ [ 1, :bytes, digest ] ]), 41)
      close
      true
    end

    def close = @conn&.close

    private

    def ask(field, body, expect)
      @conn.send_msg([ [ 1, :varint, 2 ], [ 2, :enum, 200 ], [ field, :message, body ] ])
      reply = @conn.read_msg or raise Error, "a TV não respondeu ao pareamento"
      status = reply[2].first.to_i
      raise Error, "a TV recusou o pareamento (#{status})" unless status == 200 && reply.key?(expect)

      reply
    end
  end

  # Sessão de controle: faz o aperto de mão e junta o estado que a TV manda.
  class Remote
    attr_reader :state

    def self.open(host, port, pair)
      r = new(host, port, pair)
      yield r
    ensure
      r&.close
    end

    def initialize(host, port, pair)
      @conn = Conn.new(host, port, pair)
      @state = {}
      handle(@conn.read_msg || raise(Error, "a TV não respondeu")) until @active
    rescue StandardError
      close
      raise
    end

    # Lê o que a TV mandar por até `seconds` (estado e pings).
    def settle(seconds = 1.0)
      deadline = Time.now + seconds
      while (left = deadline - Time.now).positive? && (m = @conn.read_msg(left))
        handle(m)
      end
      @state
    end

    def key(code) = @conn.send_msg([ [ 10, :message, Proto.encode([ [ 1, :enum, code ], [ 2, :enum, 3 ] ]) ] ]) # 3 = toque curto
    def launch(link) = @conn.send_msg([ [ 90, :message, Proto.encode([ [ 1, :string, link ] ]) ] ])
    def close = @conn&.close

    private

    def handle(m)
      if (c = m[1].first)
        info = Proto.decode(Proto.decode(c)[2].first.to_s)
        @state.merge!("model" => Proto.string(info[1].first), "vendor" => Proto.string(info[2].first)).compact!
        device = Proto.encode([ [ 1, :string, "Minha Automação" ], [ 2, :string, "MinhaSuite" ], [ 3, :varint, 1 ], [ 4, :string, "1" ],
                                [ 5, :string, "atvremote" ], [ 6, :string, "1.0.0" ] ])
        @conn.send_msg([ [ 1, :message, Proto.encode([ [ 1, :varint, FEATURES ], [ 2, :message, device ] ]) ] ])
      elsif m.key?(2)
        @conn.send_msg([ [ 2, :message, Proto.encode([ [ 1, :varint, FEATURES ] ]) ] ])
        @active = true
      elsif (p = m[8].first)
        @conn.send_msg([ [ 9, :message, Proto.encode([ [ 1, :varint, Proto.decode(p)[1].first.to_i ] ]) ] ])
      elsif (s = m[40].first)
        @state["on"] = Proto.decode(s)[1].first == 1
      elsif (v = m[50].first)
        d = Proto.decode(v)
        @state.merge!("max" => d[6].first, "volume" => d[7].first, "muted" => d[8].first == 1)
      elsif (ime = m[20].first)
        app = Proto.decode(Proto.decode(ime)[1].first.to_s)[12].first
        @state["app"] = Proto.string(app) if app
      elsif m.key?(3)
        raise Error, "a TV recusou a sessão"
      end
    end
  end
end
