require "socket"

# SNMP v2c, só GET (resto; impressoras Brother e o que mais falar SNMP):
# codifica o pedido em BER, manda por UDP 161 e devolve {oid => valor}.
# Sem gem: o que precisa de BER é pouco (INTEGER, OCTET STRING, NULL, OID,
# SEQUENCE e os tipos de contador). OID que o aparelho não tem não volta.
module Snmp
  class Error < Integrations::Error; end

  TAGS = { int: 0x02, str: 0x04, null: 0x05, oid: 0x06, seq: 0x30, get: 0xA0 }.freeze
  NUMBERS = [ 0x02, 0x41, 0x42, 0x43, 0x46 ].freeze # INTEGER, Counter32, Gauge32, TimeTicks, Counter64

  module_function

  def get(host, oids, community: "public", port: 161, timeout: 3)
    id = rand(1..0x7FFFFFFF)
    sock = UDPSocket.new
    sock.connect(host, port)
    sock.send(request(id, community, oids), 0)
    raise Error, "SNMP: sem resposta de #{host}" unless sock.wait_readable(timeout)

    response(sock.recv(65_535), id)
  rescue SystemCallError, SocketError => e
    raise Error, "SNMP: #{e.class.name.demodulize}"
  ensure
    sock&.close
  end

  # --- BER ---
  def tlv(tag, body) = [ tag ].pack("C") + length(body.bytesize) + body
  def length(n) = n < 128 ? [ n ].pack("C") : [ 0x80 | (b = int_bytes(n)).bytesize ].pack("C") + b
  def int_bytes(n) = n.zero? ? "\0".b : [ n.to_s(16).rjust(n.to_s(16).size + (n.to_s(16).size.odd? ? 1 : 0), "0") ].pack("H*")

  # INTEGER em complemento de dois, com o mínimo de bytes.
  def int(n)
    b = [ n ].pack("q>")
    b = b.byteslice(1..) while b.bytesize > 1 && ((b.getbyte(0).zero? && b.getbyte(1) < 0x80) || (b.getbyte(0) == 0xFF && b.getbyte(1) >= 0x80))
    tlv(TAGS[:int], b)
  end

  def oid(text)
    a, b, *rest = text.split(".").map(&:to_i)
    tlv(TAGS[:oid], ([ (40 * a) + b ] + rest.flat_map { |n| base128(n) }).pack("C*"))
  end

  def base128(n)
    out = [ n & 0x7F ]
    out.unshift((n & 0x7F) | 0x80) while (n >>= 7).positive?
    out
  end

  def request(id, community, oids)
    binds = tlv(TAGS[:seq], oids.map { |o| tlv(TAGS[:seq], oid(o) + tlv(TAGS[:null], "")) }.join)
    pdu = tlv(TAGS[:get], int(id) + int(0) + int(0) + binds)
    tlv(TAGS[:seq], int(1) + tlv(TAGS[:str], community.to_s.b) + pdu)
  end

  # TLV no início de `data` → [tag, corpo, resto].
  def read(data)
    tag = data.getbyte(0) or raise Error, "SNMP: resposta curta"
    len = data.getbyte(1).to_i
    head = 2
    if len >= 0x80
      n = len & 0x7F
      len = data.byteslice(2, n).unpack1("H*").to_i(16)
      head += n
    end
    [ tag, data.byteslice(head, len).to_s, data.byteslice((head + len)..).to_s ]
  end

  def items(data)
    out = []
    until data.empty?
      tag, body, data = read(data)
      out << [ tag, body ]
    end
    out
  end

  def decode_oid(body)
    bytes = body.unpack("C*")
    first = bytes.shift.to_i
    arcs = [ first / 40, first % 40 ]
    n = 0
    bytes.each do |b|
      n = (n << 7) | (b & 0x7F)
      next if b & 0x80 != 0

      arcs << n
      n = 0
    end
    arcs.join(".")
  end

  def value(tag, body)
    return body.unpack1("H*").to_i(16) if NUMBERS.include?(tag) && tag != 0x02
    return (body.empty? ? 0 : body.unpack1("H*").to_i(16) - (body.getbyte(0) >= 0x80 ? 1 << (8 * body.bytesize) : 0)) if tag == 0x02
    return body.dup.force_encoding("UTF-8").scrub.delete("\0").strip if tag == TAGS[:str]
    return decode_oid(body) if tag == TAGS[:oid]

    nil # NULL, noSuchObject (0x80), noSuchInstance (0x81), endOfMibView (0x82)
  end

  def response(data, id)
    _, msg, = read(data.b)
    (_, _), (_, _), (_, pdu) = items(msg)
    (_, rid), (_, status), _, (_, binds) = items(pdu)
    raise Error, "SNMP: resposta de outro pedido" unless value(0x02, rid) == id
    raise Error, "SNMP: erro #{value(0x02, status)}" unless value(0x02, status).zero?

    items(binds).to_h do |_, bind|
      (_, o), (tag, body) = items(bind)
      [ decode_oid(o), value(tag, body) ]
    end.compact
  end
end
