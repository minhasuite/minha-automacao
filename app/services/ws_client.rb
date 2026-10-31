require "websocket/driver"
require "socket"
require "openssl"

# Cliente WebSocket síncrono (Pacote 1: LG webOS, Samsung Tizen, Matter
# Server, Shelly Gen2) sobre o `websocket-driver` que já vem com o Action
# Cable. `ws://` ou `wss://` (TV e Shelly usam certificado próprio: sem
# verificação, só na rede de casa). Uso: `WsClient.open(url) { |ws|
# ws.send_json(...); ws.read_json(5) }`.
class WsClient
  class Error < StandardError; end

  attr_reader :url

  def self.open(url, **)
    ws = new(url, **).connect
    yield ws
  ensure
    ws&.close
  end

  def initialize(url, headers: {}, timeout: 5)
    @url = url
    @headers = headers
    @timeout = timeout
    @inbox = []
  end

  def connect
    uri = URI.parse(@url)
    tcp = Socket.tcp(uri.host, uri.port, connect_timeout: @timeout)
    @sock = uri.scheme == "wss" ? tls(tcp, uri.host) : tcp
    @driver = WebSocket::Driver.client(self)
    @headers.each { |k, v| @driver.set_header(k, v) }
    @driver.on(:message) { |e| @inbox << e.data }
    @driver.on(:close) { @closed = true }
    @driver.on(:error) { |e| @error = e.message }
    @driver.start
    pump until @driver.state == :open || @closed || timed_out?(deadline)
    raise Error, @error || "WebSocket não abriu em #{@url}" unless @driver.state == :open

    self
  rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError => e
    raise Error, "Sem conexão com #{uri&.host}: #{e.message}"
  end

  # O driver escreve por aqui.
  def write(data) = @sock.write(data)

  def send_text(text) = @driver.text(text)
  def send_json(obj) = send_text(obj.to_json)

  # Próxima mensagem (texto) ou nil depois de `timeout` segundos.
  def read(timeout = @timeout)
    limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    pump(limit) while @inbox.empty? && !@closed && !timed_out?(limit)
    @inbox.shift
  end

  def read_json(timeout = @timeout) = (m = read(timeout)) && JSON.parse(m)

  def closed? = @closed || @sock.nil?

  def close
    @driver&.close
    @sock&.close
  rescue IOError, SystemCallError
    nil
  ensure
    @sock = nil
  end

  private

  def deadline = @deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
  def timed_out?(limit) = Process.clock_gettime(Process::CLOCK_MONOTONIC) >= limit

  def pump(limit = deadline)
    left = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return if left <= 0

    buffered = @sock.respond_to?(:pending) && @sock.pending.positive? # TLS já decifrado
    return unless buffered || IO.select([ @sock ], nil, nil, left)

    data = @sock.read_nonblock(65_536, exception: false)
    return @closed = true if data.nil?
    return if data.is_a?(Symbol) # :wait_readable / :wait_writable

    @driver.parse(data)
  end

  def tls(tcp, host)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE # aparelho da rede de casa com certificado próprio
    ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
    ssl.hostname = host
    ssl.sync_close = true
    ssl.connect
    ssl
  end
end
