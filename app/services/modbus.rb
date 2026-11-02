require "socket"

# Modbus TCP mínimo (integ2: inversores SunSpec): lê registradores
# (função 3) de uma unidade. Só leitura; nada aqui escreve no aparelho.
module Modbus
  class Error < StandardError; end

  module_function

  # → [uint16…]
  def read(host, port, unit, address, count, timeout: 5)
    Socket.tcp(host, port, connect_timeout: timeout) do |sock|
      tid = rand(1..0xFFFF)
      sock.write([ tid, 0, 6, unit, 3, address, count ].pack("nnnCCnn"))
      _tid, _proto, len, _unit, fn = read_exact(sock, 8, timeout).unpack("nnnCC")
      body = read_exact(sock, len - 2, timeout)
      raise Error, "O inversor recusou a leitura do registrador #{address} (código #{body.getbyte(0)})." if fn.anybits?(0x80)

      body.byteslice(1..).unpack("n*")
    end
  rescue SystemCallError, SocketError, IOError => e
    raise Error, "Sem conexão com #{host}:#{port} (#{e.class.name.demodulize})."
  end

  def read_exact(sock, n, timeout)
    out = +"".b
    while out.bytesize < n
      raise Error, "O inversor não respondeu." unless IO.select([ sock ], nil, nil, timeout)

      chunk = sock.read_nonblock(n - out.bytesize, exception: false)
      raise Error, "O inversor fechou a conexão." if chunk.nil?

      out << chunk unless chunk.is_a?(Symbol)
    end
    out
  end

  def int16(v) = v >= 0x8000 ? v - 0x10000 : v
end
