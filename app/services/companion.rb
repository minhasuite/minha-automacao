require "socket"

# resto2 (grupo 9 #22; o `apple_tv` do HA, parte Companion do pyatv):
# protocolo Companion do tvOS, o do Controle Remoto da Central de Controle do
# iPhone, em TCP na porta anunciada em `_companion-link._tcp`.
# - Quadro: tipo (1 byte) + tamanho (3 bytes, big-endian) + corpo em OPACK.
# - Pareamento: o pair-setup do HAP (`Hap::Client`, SRP com o PIN de 4
#   dígitos que a Apple TV mostra) dentro de quadros PS_Start/PS_Next; depois,
#   pair-verify em PV_Start/PV_Next e os quadros seguem cifrados
#   (ChaCha20-Poly1305, chaves "ClientEncrypt-main"/"ServerEncrypt-main",
#   nonce = contador de 12 bytes, cabeçalho do quadro como AAD).
# - Mensagens: {"_i" => nome, "_x" => id, "_t" => 2 (pedido), "_c" => conteúdo};
#   a resposta volta com o mesmo "_x" e "_t" => 3.
module Companion
  Error = Class.new(StandardError)
  PS_START, PS_NEXT, PV_START, PV_NEXT, E_OPACK = 3, 4, 5, 6, 8
  HID = { "up" => 1, "down" => 2, "left" => 3, "right" => 4, "menu" => 5, "select" => 6, "home" => 7, "volume_up" => 8, "volume_down" => 9,
          "siri" => 10, "screensaver" => 11, "sleep" => 12, "wake" => 13, "play_pause" => 14, "channel_up" => 15, "channel_down" => 16,
          "guide" => 17, "page_up" => 18, "page_down" => 19 }.freeze
  MEDIA = { "resume" => 1, "pause" => 2, "next" => 3, "previous" => 4 }.freeze
  ASLEEP = 1 # FetchAttentionState: 1 dormindo, 2 descanso de tela, 3 acordada, 4 parada

  # OPACK (serialização binária da Apple): o que o Companion usa. Sem as
  # referências na escrita (válido); na leitura, as referências (0xA0…0xC4)
  # apontam para os valores de mais de 1 byte já lidos.
  module Opack
    module_function

    def pack(v)
      case v
      when true then "\x01".b
      when false then "\x02".b
      when nil then "\x04".b
      when Integer then int(v)
      when Float then [ 0x36, v ].pack("CE")
      when Symbol then pack(v.to_s)
      when String then v.encoding == Encoding::BINARY ? sized(v, 0x70, [ 0x91, 0x92, 0x93 ]) : sized(v.encode("UTF-8").b, 0x40, [ 0x61, 0x62, 0x64 ])
      when Array then container(0xD0, v.map { |x| pack(x) })
      when Hash then container(0xE0, v.map { |k, x| pack(k) + pack(x) })
      else raise ArgumentError, "OPACK: #{v.class}"
      end
    end

    def int(v)
      raise ArgumentError, "OPACK: inteiro negativo" if v.negative?
      return [ 0x08 + v ].pack("C") if v < 0x28
      return [ 0x30, v ].pack("CC") if v <= 0xFF
      return [ 0x31, v ].pack("Cv") if v <= 0xFFFF
      return [ 0x32, v ].pack("CV") if v <= 0xFFFF_FFFF

      [ 0x33, v ].pack("CQ<")
    end

    def sized(bytes, inline, (one, two, four))
      n = bytes.bytesize
      head = if n <= 0x20 then [ inline + n ].pack("C")
      elsif n <= 0xFF then [ one, n ].pack("CC")
      elsif n <= 0xFFFF then [ two, n ].pack("Cv")
      else [ four, n ].pack("CV")
      end
      head + bytes
    end

    def container(base, items) = (items.size < 15 ? [ base + items.size ].pack("C") + items.join : [ base + 15 ].pack("C") + items.join + "\x03".b).b

    def unpack(data) = read(data.to_s.b, 0, [])[0]

    # → [valor, próxima posição]
    def read(d, pos, objs)
      t = d.getbyte(pos) or raise Error, "OPACK truncado"
      start = pos
      pos += 1
      value = case t
      when 0x01 then true
      when 0x02 then false
      when 0x04 then nil
      when 0x05 then d.byteslice(pos, 16).tap { pos += 16 }
      when 0x06 then d.byteslice(pos, 8).unpack1("G").tap { pos += 8 }
      when 0x08..0x2F then t - 8
      when 0x35 then d.byteslice(pos, 4).unpack1("e").tap { pos += 4 }
      when 0x36 then d.byteslice(pos, 8).unpack1("E").tap { pos += 8 }
      when 0x30..0x33 then le(d, pos, 1 << (t & 0xF)).tap { pos += 1 << (t & 0xF) }
      when 0x40..0x60, 0x61..0x64, 0x70..0x90, 0x91..0x94
        len, pos = length(d, pos, t)
        s = d.byteslice(pos, len)
        pos += len
        t < 0x70 ? s.force_encoding("UTF-8") : s
      when 0xA0..0xC0 then return [ objs.fetch(t - 0xA0), pos ]
      when 0xC1..0xC4 then return [ objs.fetch(le(d, pos, t - 0xC0)), pos + t - 0xC0 ]
      when 0xD0..0xDF, 0xE0..0xEF
        dict = t >= 0xE0
        count = t & 0xF
        items = []
        while count == 15 ? d.getbyte(pos) != 0x03 : items.size < count * (dict ? 2 : 1)
          x, pos = read(d, pos, objs)
          items << x
        end
        pos += 1 if count == 15
        return [ dict ? items.each_slice(2).to_h : items, pos ]
      else raise Error, "OPACK: tipo 0x#{t.to_s(16)}"
      end
      objs << value if pos - start > 1
      [ value, pos ]
    end

    def le(d, pos, n) = d.byteslice(pos, n).bytes.each_with_index.sum { |b, i| b << (8 * i) }

    def length(d, pos, t)
      case t
      when 0x40..0x60 then [ t - 0x40, pos ]
      when 0x70..0x90 then [ t - 0x70, pos ]
      when 0x61..0x64 then [ le(d, pos, t - 0x60), pos + t - 0x60 ]
      else n = 1 << ((t & 0xF) - 1)
           [ le(d, pos, n), pos + n ]
      end
    end
  end

  # Cliente: o pareamento e a verificação são os do HAP; só o transporte muda.
  class Client < Hap::Client
    def pin_code(code)
      pin = code.to_s.delete("^0-9")
      raise Hap::Error, "O PIN da Apple TV tem 4 dígitos." unless pin.size == 4

      pin
    end

    def session_keys!(shared)
      @write = Hap.hkdf(shared, "", "ClientEncrypt-main")
      @read = Hap.hkdf(shared, "", "ServerEncrypt-main")
    end

    # Pedido → conteúdo da resposta ("_c").
    def request(id, content = {})
      @xid = (@xid || rand(1..0xFFFF)) + 1
      frame(E_OPACK, Opack.pack("_i" => id, "_x" => @xid, "_t" => 2, "_c" => content))
      loop do
        _type, body = read_frame
        msg = Opack.unpack(body)
        next unless msg.is_a?(Hash) && msg["_x"] == @xid && msg["_t"] == 3 # eventos no meio

        raise Error, "Apple TV: #{msg['_em'] || msg['_ec']}" if msg["_em"] || msg["_ec"]

        return msg["_c"] || {}
      end
    end

    # Começa a sessão do controle remoto (o que o app do iPhone faz).
    def start!
      request("_systemInfo", "_bf" => 0, "_cf" => 512, "_clFl" => 128, "_i" => SecureRandom.hex(6), "model" => "iPhone14,3", "name" => "Minha Automação",
                             "_idsID" => SecureRandom.uuid.upcase, "_pubID" => SecureRandom.hex(6).scan(/../).join(":"), "_sf" => 256, "_sv" => "170.18", "_stA" => [])
      request("_sessionStart", "_srvT" => "com.apple.tvremoteservices", "_sid" => SecureRandom.random_number(1 << 32))
      self
    end

    def press(button)
      code = HID.fetch(button.to_s) { raise Error, "Apple TV: botão #{button}?" }
      request("_hidC", "_hBtS" => 1, "_hidC" => code)
      request("_hidC", "_hBtS" => 2, "_hidC" => code)
    end

    private

    def tlv_post(path, pairs)
      setup = path == "/pair-setup"
      first = pairs.assoc(Hap::Tlv::STATE)&.last == 1
      body = { "_pd" => Hap::Tlv.encode(pairs) }
      body[setup ? "_pwTy" : "_auTy"] = setup ? 1 : 4 if first
      frame(setup ? (first ? PS_START : PS_NEXT) : (first ? PV_START : PV_NEXT), Opack.pack(body))
      Hap::Tlv.decode(Opack.unpack(read_frame[1]).to_h["_pd"])
    end

    def nonce(n) = [ n ].pack("Q<") + ("\0" * 4).b

    def frame(type, body)
      if @write
        head = [ type ].pack("C") + [ body.bytesize + 16 ].pack("N")[1, 3]
        sock.write(head + Hap.seal(@write, nonce(@out), body, head))
        @out += 1
      else
        sock.write([ type ].pack("C") + [ body.bytesize ].pack("N")[1, 3] + body)
      end
    end

    def read_frame
      head = exact(4)
      type = head.getbyte(0)
      body = exact(("\0".b + head.byteslice(1, 3)).unpack1("N"))
      return [ type, body ] unless @read

      [ type, Hap.open(@read, nonce(@in), body, head) ].tap { @in += 1 }
    end

    def exact(n)
      out = +"".b
      while out.bytesize < n
        raise Error, "A Apple TV não respondeu em #{TIMEOUT} s." unless sock.wait_readable(TIMEOUT)

        out << sock.readpartial(n - out.bytesize)
      end
      out
    rescue EOFError
      raise Error, "A Apple TV fechou a conexão."
    end
  end
end
