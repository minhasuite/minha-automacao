# Protobuf mínimo, sem .proto nem gem: o bastante para a API nativa do
# ESPHome e o protocolo do Chromecast (Pacote 1). `encode` recebe
# [[campo, tipo, valor]] e `decode` devolve {campo => [valores crus]}
# (varint = Integer; len = String binária; fixed32/64 = 4/8 bytes, ler com
# `float`/`fixed32`/`double`).
module Proto
  TYPES = { varint: 0, bool: 0, enum: 0, sint: 0, fixed64: 1, double: 1, string: 2, bytes: 2, message: 2, fixed32: 5, float: 5 }.freeze

  module_function

  def varint(n)
    n &= 0xFFFF_FFFF_FFFF_FFFF if n.negative?
    out = +"".b
    loop do
      byte = n & 0x7F
      n >>= 7
      out << (n.zero? ? byte : byte | 0x80)
      return out if n.zero?
    end
  end

  # → [valor, próxima posição]
  def read_varint(bytes, pos)
    n = 0
    shift = 0
    loop do
      byte = bytes.getbyte(pos) or raise ArgumentError, "varint truncado"
      pos += 1
      n |= (byte & 0x7F) << shift
      return [ n, pos ] if byte < 0x80

      shift += 7
    end
  end

  def encode(fields)
    fields.each_with_object(+"".b) do |(num, type, value), out|
      next if value.nil?

      out << varint((num << 3) | TYPES.fetch(type)) << encode_value(type, value)
    end
  end

  def encode_value(type, value)
    case type
    when :bool then varint(value ? 1 : 0)
    when :varint, :enum then varint(value.to_i)
    when :sint then varint((value << 1) ^ (value >> 63))
    when :fixed32 then [ value ].pack("V")
    when :float then [ value.to_f ].pack("e")
    when :fixed64 then [ value ].pack("Q<")
    when :double then [ value.to_f ].pack("E")
    else s = value.to_s.b
         varint(s.bytesize) + s
    end
  end

  def decode(bytes)
    bytes = bytes.b
    pos = 0
    fields = Hash.new { |h, k| h[k] = [] }
    while pos < bytes.bytesize
      key, pos = read_varint(bytes, pos)
      num = key >> 3
      case key & 7
      when 0 then value, pos = read_varint(bytes, pos)
      when 1 then value, pos = bytes.byteslice(pos, 8), pos + 8
      when 2
        len, pos = read_varint(bytes, pos)
        value, pos = bytes.byteslice(pos, len), pos + len
      when 5 then value, pos = bytes.byteslice(pos, 4), pos + 4
      else raise ArgumentError, "tipo de campo #{key & 7} sem suporte"
      end
      fields[num] << value
    end
    fields
  end

  def float(raw) = raw&.unpack1("e")
  def double(raw) = raw&.unpack1("E")
  def fixed32(raw) = raw&.unpack1("V")
  def string(raw) = raw&.dup&.force_encoding("UTF-8")&.scrub
end
