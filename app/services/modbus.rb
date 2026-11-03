require "socket"

# Modbus TCP mínimo (integ2: inversores SunSpec; catalogo: integração Modbus
# genérica): lê registradores (função 3 holding, 4 input) e bobinas (1 coil,
# 2 discrete input) de uma unidade e escreve um registrador (6) ou uma bobina (5).
module Modbus
  class Error < StandardError; end

  module_function

  # PDU → corpo da resposta (sem o código da função).
  def request(host, port, unit, pdu, timeout: 5)
    Socket.tcp(host, port, connect_timeout: timeout) do |sock|
      tid = rand(1..0xFFFF)
      sock.write([ tid, 0, pdu.bytesize + 1, unit ].pack("nnnC") + pdu)
      _tid, _proto, len, _unit, fn = read_exact(sock, 8, timeout).unpack("nnnCC")
      body = read_exact(sock, len - 2, timeout)
      raise Error, "O aparelho recusou o pedido no registrador (código #{body.getbyte(0)})." if fn.anybits?(0x80)

      body
    end
  rescue SystemCallError, SocketError, IOError => e
    raise Error, "Sem conexão com #{host}:#{port} (#{e.class.name.demodulize})."
  end

  # → [uint16…] (fn 3/4) ou [true/false…] (fn 1/2).
  def read(host, port, unit, address, count, timeout: 5, fn: 3)
    body = request(host, port, unit, [ fn, address, count ].pack("Cnn"), timeout: timeout)
    return body.byteslice(1..).unpack("n*") if fn >= 3

    body.byteslice(1..).unpack1("b*").chars.first(count).map { |b| b == "1" }
  end

  # Escreve um registrador (fn 6, 0..65535) ou uma bobina (fn 5, true/false).
  def write(host, port, unit, address, value, timeout: 5, fn: 6)
    raw = fn == 5 ? (value ? 0xFF00 : 0) : value.to_i & 0xFFFF
    request(host, port, unit, [ fn, address, raw ].pack("Cnn"), timeout: timeout)
  end

  def read_exact(sock, n, timeout)
    out = +"".b
    while out.bytesize < n
      raise Error, "O aparelho não respondeu." unless IO.select([ sock ], nil, nil, timeout)

      chunk = sock.read_nonblock(n - out.bytesize, exception: false)
      raise Error, "O aparelho fechou a conexão." if chunk.nil?

      out << chunk unless chunk.is_a?(Symbol)
    end
    out
  end

  def int16(v) = v >= 0x8000 ? v - 0x10000 : v
end
