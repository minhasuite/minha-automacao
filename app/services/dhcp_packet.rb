# Pacote DHCP (BOOTP, RFC 2131/2132) → o que a descoberta usa: MAC, nome que
# o aparelho pediu (opção 12), IP pedido ou dado, classe do fabricante (60).
# Ruby puro (sem Rails): o bin/dhcp-watch usa o mesmo arquivo. resto (7.23).
module DhcpPacket
  COOKIE = [ 99, 130, 83, 99 ].pack("C4")
  TYPES = { 1 => "discover", 3 => "request", 5 => "ack", 8 => "inform" }.freeze

  module_function

  # → {"mac", "hostname", "ip", "vendor", "type"} ou nil se não for DHCP de cliente.
  def parse(data)
    data = data.to_s.b
    return nil if data.bytesize < 240 || data.byteslice(236, 4) != COOKIE

    op, htype, hlen = data.unpack("C3")
    return nil unless htype == 1 && hlen == 6 && [ 1, 2 ].include?(op)

    opts = options(data.byteslice(240..))
    type = TYPES[opts[53]&.getbyte(0)] or return nil
    ip = opts[50] || (data.byteslice(16, 4) unless op == 1) || data.byteslice(12, 4)
    { "mac" => data.byteslice(28, 6).unpack("C6").map { |b| format("%02X", b) }.join(":"), "hostname" => text(opts[12]),
      "ip" => (ip.unpack("C4").join(".") if ip && ip.bytesize == 4 && ip != "\0\0\0\0".b), "vendor" => text(opts[60]), "type" => type }.compact
  end

  def options(body)
    out = {}
    pos = 0
    while pos < body.bytesize
      code = body.getbyte(pos)
      break if code == 255

      pos += 1
      next if code.zero?

      len = body.getbyte(pos) or break
      out[code] = body.byteslice(pos + 1, len)
      pos += len + 1
    end
    out
  end

  def text(bytes)
    s = bytes.to_s.dup.force_encoding("UTF-8").scrub.delete("\0").strip
    s.empty? ? nil : s[0, 63]
  end
end
