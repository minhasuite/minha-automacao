# resto2: broker MQTT de mentira da Roborock em 127.0.0.1 (pacotes do gem
# mqtt), do lado do robô: confere usuário/senha derivados do rriot, decifra
# o pedido 101 com a chave local e responde 102 no tópico assinado.
class FakeRoborockMqtt
  attr_reader :port, :calls, :topics

  def initialize(local_key:, user:, pass:)
    @key, @user, @pass = local_key, user, pass
    @calls = []
    @topics = []
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new do
      loop do
        Thread.new(@server.accept) do |s|
          serve(s)
        rescue IOError, SystemCallError, MQTT::Exception
          nil
        ensure
          s.close
        end
      end
    rescue IOError
      nil
    end
  end

  def stop
    @thread.kill
    @server.close
  end

  def answer(method)
    case method
    when "get_status" then [ { "state" => 5, "battery" => 87, "fan_power" => 103, "clean_area" => 12_500_000, "clean_time" => 1200, "error_code" => 0 } ]
    when "get_room_mapping" then [ [ 16, "501" ], [ 17, "502" ] ]
    else [ "ok" ]
    end
  end

  private

  def serve(s)
    c = MQTT::Packet.read(s)
    ok = c.username == @user && c.password == @pass
    s.write(MQTT::Packet::Connack.new(return_code: ok ? 0 : 5).to_s)
    return unless ok

    out = nil
    loop do
      pk = MQTT::Packet.read(s)
      case pk
      when MQTT::Packet::Subscribe
        out = pk.topics.first.first
        @topics << out
        s.write(MQTT::Packet::Suback.new(id: pk.id, return_codes: [ 0 ]).to_s)
      when MQTT::Packet::Publish
        @topics << pk.topic
        _protocol, body = Roborock.decode(@key, pk.payload)
        req = JSON.parse(JSON.parse(body).dig("dps", "101"))
        @calls << [ req["method"], req["params"] ]
        other = { dps: { "102" => { id: 1, result: [] }.to_json } }.to_json # resposta de outro pedido: o cliente ignora
        s.write(MQTT::Packet::Publish.new(topic: out, payload: Roborock.encode(@key, 102, other)).to_s)
        reply = { dps: { "102" => { id: req["id"], result: answer(req["method"]) }.to_json }, t: Time.now.to_i }.to_json
        s.write(MQTT::Packet::Publish.new(topic: out, payload: Roborock.encode(@key, 102, reply)).to_s)
      when MQTT::Packet::Pingreq then s.write(MQTT::Packet::Pingresp.new.to_s)
      when MQTT::Packet::Disconnect then break
      end
    end
  end
end
