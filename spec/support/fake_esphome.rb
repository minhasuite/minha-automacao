# Pacote 1: aparelho ESPHome falso (TCPServer numa thread) para o esphome_spec:
# API nativa sem e com Noise (lado responder), entidades, estados, comandos e ping.
class FakeEsphome
  attr_reader :port, :commands, :pongs

  ENTITIES = [
    [ 12, [ [ 1, :string, "movimento" ], [ 2, :fixed32, 1 ], [ 3, :string, "Movimento" ], [ 5, :string, "motion" ] ] ],
    [ 12, [ [ 1, :string, "status" ], [ 2, :fixed32, 9 ], [ 3, :string, "Status" ], [ 6, :bool, true ] ] ],
    [ 16, [ [ 1, :string, "temp" ], [ 2, :fixed32, 2 ], [ 3, :string, "Temperatura" ], [ 6, :string, "°C" ], [ 7, :varint, 1 ],
            [ 9, :string, "temperature" ], [ 10, :enum, 1 ] ] ],
    [ 16, [ [ 1, :string, "oculto" ], [ 2, :fixed32, 10 ], [ 3, :string, "Oculto" ], [ 12, :bool, true ] ] ],
    [ 17, [ [ 1, :string, "rele" ], [ 2, :fixed32, 3 ], [ 3, :string, "Relé" ] ] ],
    [ 15, [ [ 1, :string, "luz" ], [ 2, :fixed32, 4 ], [ 3, :string, "Luz" ], [ 12, :bytes, Proto.varint(1) + Proto.varint(3) ] ] ],
    [ 13, [ [ 1, :string, "portao" ], [ 2, :fixed32, 5 ], [ 3, :string, "Portão" ], [ 6, :bool, false ], [ 8, :string, "gate" ] ] ],
    [ 18, [ [ 1, :string, "versao" ], [ 2, :fixed32, 6 ], [ 3, :string, "Versão" ] ] ],
    [ 49, [ [ 1, :string, "alvo" ], [ 2, :fixed32, 7 ], [ 3, :string, "Alvo" ], [ 6, :float, 10 ], [ 7, :float, 30 ], [ 8, :float, 0.5 ], [ 11, :string, "°C" ] ] ],
    [ 61, [ [ 1, :string, "reiniciar" ], [ 2, :fixed32, 8 ], [ 3, :string, "Reiniciar" ] ] ]
  ].freeze

  def initialize(key: nil, password: nil)
    @key = key
    @password = password
    @commands = []
    @pongs = 0
    @state = { 1 => [ 21, [ [ 1, :fixed32, 1 ], [ 2, :bool, true ] ] ], 2 => [ 25, [ [ 1, :fixed32, 2 ], [ 2, :float, 22.456 ] ] ],
               3 => [ 26, [ [ 1, :fixed32, 3 ], [ 2, :bool, false ] ] ], 4 => [ 24, [ [ 1, :fixed32, 4 ], [ 2, :bool, true ], [ 3, :float, 0.5 ] ] ],
               5 => [ 22, [ [ 1, :fixed32, 5 ], [ 3, :float, 0.0 ] ] ], 6 => [ 27, [ [ 1, :fixed32, 6 ], [ 2, :string, "2026.10.0" ] ] ],
               7 => [ 50, [ [ 1, :fixed32, 7 ], [ 2, :float, 21.0 ] ] ] }
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new do
      loop { Thread.new(@server.accept) { |s| serve(s) } }
    rescue IOError
      nil
    end
  end

  def stop
    @server.close
    @thread.kill
  end

  private

  def serve(sock)
    @sock = sock
    @noise = handshake if @key
    loop do
      msg = read_msg or break
      type, data = msg
      f = Proto.decode(data)
      case type
      when 1 then send_msg(2, [ [ 1, :varint, 1 ], [ 2, :varint, 10 ], [ 3, :string, "fake" ], [ 4, :string, "sala" ] ])
      when 3 then send_msg(4, [ [ 1, :bool, @password.present? && Proto.string(f[1]&.first) != @password ] ])
      when 9 then send_msg(10, [ [ 2, :string, "sala" ], [ 3, :string, "AA:BB:CC:DD:EE:FF" ], [ 4, :string, "2026.10.0" ], [ 6, :string, "esp32dev" ],
                                 [ 13, :string, "Sensor da sala" ] ])
      when 11
        ENTITIES.each { |t, fields| send_msg(t, fields) }
        send_msg(19)
      when 20
        send_msg(7) # ping do aparelho: o cliente responde sozinho
        @state.each_value { |t, fields| send_msg(t, fields) }
      when 8 then @pongs += 1
      when 5 then send_msg(6) && break
      else command(type, f)
      end
    end
  rescue Esphome::Error, IOError, SystemCallError
    nil
  ensure
    sock.close
  end

  def command(type, f)
    key = Proto.fixed32(f[1]&.first)
    @commands << [ type, key, f ]
    reply = case type
    when 33 then [ 26, [ [ 1, :fixed32, key ], [ 2, :bool, f[2]&.first == 1 ] ] ]
    when 32 then [ 24, [ [ 1, :fixed32, key ], [ 2, :bool, f[3]&.first == 1 ], [ 3, :float, Proto.float(f[5]&.first) || 0.5 ] ] ]
    when 30 then [ 22, [ [ 1, :fixed32, key ], [ 3, :float, Proto.float(f[5]&.first) ] ] ]
    when 51 then [ 50, [ [ 1, :fixed32, key ], [ 2, :float, Proto.float(f[2]&.first) ] ] ]
    end
    send_msg(*reply) if reply
  end

  def handshake
    head = @sock.read(3)
    unless head&.getbyte(0) == 1 # cliente sem chave: o aparelho avisa e fecha
      frame("\x01Bad indicator byte".b)
      raise Esphome::Error, "sem chave"
    end
    msg = read_frame
    noise = Esphome::Noise.new(Esphome::Noise.psk(@key), initiator: false)
    begin
      noise.read_first(msg.byteslice(1..))
    rescue Esphome::Error
      frame("\x01".b + "fake\x00".b)
      frame("\x01Handshake MAC failure".b)
      raise
    end
    frame("\x01".b + "fake\x00AA:BB\x00".b)
    frame("\x00".b + noise.write_second)
    noise
  end

  def frame(payload) = @sock.write("\x01".b + [ payload.bytesize ].pack("n") + payload)

  def read_frame
    head = @sock.read(3) or return
    size = head.byteslice(1, 2).unpack1("n")
    size.zero? ? "".b : @sock.read(size)
  end

  def send_msg(type, fields = [])
    data = Proto.encode(fields)
    if @noise
      frame(@noise.sender.encrypt("".b, [ type, data.bytesize ].pack("nn") + data))
    elsif @key.nil?
      @sock.write("\x00".b + Proto.varint(data.bytesize) + Proto.varint(type) + data)
    end
    true
  end

  def read_msg
    if @key
      data = read_frame or return
      plain = @noise.receiver.decrypt("".b, data)
      type, size = plain.unpack("nn")
      return [ type, plain.byteslice(4, size) ]
    end
    first = @sock.read(1) or return
    return unless first == "\x00".b

    size = varint
    type = varint
    [ type, size.zero? ? "".b : @sock.read(size) ]
  end

  def varint
    n = 0
    shift = 0
    loop do
      b = @sock.read(1).getbyte(0)
      n |= (b & 0x7F) << shift
      return n if b < 0x80

      shift += 7
    end
  end
end
