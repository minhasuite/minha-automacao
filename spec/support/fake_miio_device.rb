# Aparelho miIO de mentira em 127.0.0.1 (UDP, porta livre): responde ao hello
# e aos comandos MIoT cifrados com o token, guarda as propriedades e anota
# tudo o que recebeu (`calls`). `silent = true` simula aparelho fora do ar.
class FakeMiioDevice
  TOKEN = "00112233445566778899aabbccddeeff".freeze
  DID = 1_171_824_582

  attr_reader :port, :props, :calls
  attr_accessor :silent

  def initialize(props = {})
    @props = props
    @calls = []
    @socket = UDPSocket.new
    @socket.bind("127.0.0.1", 0)
    @port = @socket.addr[1]
    @token = [ TOKEN ].pack("H*")
    @thread = Thread.new { serve }
  end

  def stop
    @thread.kill
    @socket.close
  end

  private

  def serve
    loop do
      data, from = @socket.recvfrom(4096)
      next if silent

      reply = handle(data)
      @socket.send(reply, 0, from[3], from[1]) if reply
    end
  end

  def handle(data)
    return [ Miio::Protocol::MAGIC, 32, 0, DID, 4242 ].pack("nnNNN") + ("\x00".b * 16) if data == Miio::Protocol::HELLO

    req = JSON.parse(Miio::Protocol.decode(@token, data)[:payload])
    @calls << req.slice("method", "params")
    Miio::Protocol.encode(@token, did: DID, stamp: 4243, payload: { id: req["id"], result: result(req["method"], req["params"]) }.to_json)
  end

  def result(method, params)
    case method
    when "get_properties"
      params.map { |p| @props.key?([ p["siid"], p["piid"] ]) ? p.merge("code" => 0, "value" => @props[[ p["siid"], p["piid"] ]]) : p.merge("code" => -4003) }
    when "set_properties"
      params.map do |p|
        @props[[ p["siid"], p["piid"] ]] = p["value"]
        p.except("value").merge("code" => 0)
      end
    when "action" then params.merge("code" => 0, "out" => [])
    end
  end
end
