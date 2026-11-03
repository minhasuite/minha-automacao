# ondaC1: WebSocket de mentira para os clientes de serviço (Z-Wave JS, Matter
# Server). `respond` diz o resultado de cada comando (bloco recebe a mensagem
# enviada); `push` põe um evento na fila. Nada de rede.
class FakeWs
  attr_reader :sent

  # Cada conexão (`connect`) recebe o `hello` primeiro, como o servidor de verdade.
  def initialize(hello, &respond)
    @hello = hello
    @inbox = []
    @sent = []
    @respond = respond
    @closed = false
  end

  def connect = tap { @inbox.unshift(@hello) }
  def push(msg) = @inbox << msg
  def read_json(_timeout = nil) = @inbox.shift
  def closed? = @inbox.empty? && @closed
  def finish! = @closed = true
  def close = @closed = true

  def send_json(msg)
    @sent << msg
    reply = @respond.call(msg)
    @inbox << reply if reply
  end

  def commands = @sent.map { |m| m["command"] }
end
