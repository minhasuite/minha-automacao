require "digest"
require "zlib"

# resto2 (grupo 9 #34; o `roborock` do HA via python-roborock): nuvem da
# Roborock.
# - Conta: login com o código que a Roborock manda por e-mail (a senha não
#   passa pelo MA); o login devolve o `rriot` (u, s, h, k e os endereços da
#   API e do MQTT da região), guardado cifrado.
# - API REST da casa (robôs, produtos e cômodos) com autenticação Hawk.
# - MQTT da Roborock (rr/m/i/… e rr/m/o/…): mensagens do protocolo 1.0
#   (cabeçalho, carga em AES-128-ECB com a chave local do robô derivada do
#   carimbo de tempo, CRC32), pedido 101 e resposta 102 com JSON-RPC.
module Roborock
  Error = Class.new(StandardError)
  SALT = "TXdfu$jyZ#TZHsg4".freeze
  REGIONS = %w[https://usiot.roborock.com https://euiot.roborock.com https://cniot.roborock.com https://ruiot.roborock.com].freeze
  RPC_TIMEOUT = 8

  module_function

  # --- protocolo 1.0 -----------------------------------------------------------
  def encode_ts(ts)
    hex = format("%08x", ts)
    [ 5, 6, 3, 7, 1, 2, 0, 4 ].map { |i| hex[i] }.join
  end

  def cipher(mode, local_key, ts)
    c = OpenSSL::Cipher.new("aes-128-ecb").public_send(mode)
    c.key = Digest::MD5.digest(encode_ts(ts) + local_key.to_s + SALT)
    c
  end

  def encode(local_key, protocol, payload, seq: rand(1..0xFFFF), random: rand(10_000..99_999), ts: Time.now.to_i)
    c = cipher(:encrypt, local_key, ts)
    enc = c.update(payload) + c.final
    msg = "1.0".b + [ seq, random, ts, protocol, enc.bytesize ].pack("NNNnn") + enc
    msg + [ Zlib.crc32(msg) ].pack("N")
  end

  # → [protocolo, carga decifrada]
  def decode(local_key, data)
    data = data.to_s.b
    raise Error, "Roborock: mensagem fora do protocolo 1.0" unless data.byteslice(0, 3) == "1.0" && data.bytesize >= 23

    _seq, _random, ts, protocol, len = data.byteslice(3, 16).unpack("NNNnn")
    body = data.byteslice(19, len)
    raise Error, "Roborock: CRC não confere" unless data.byteslice(19 + len, 4).unpack1("N") == Zlib.crc32(data.byteslice(0, 19 + len))

    c = cipher(:decrypt, local_key, ts)
    [ protocol, c.update(body) + c.final ]
  rescue OpenSSL::Cipher::CipherError
    raise Error, "Roborock: chave local errada"
  end

  # --- API REST ---------------------------------------------------------------
  def client_id(email, device_id) = Base64.strict_encode64(Digest::MD5.digest(email.to_s + device_id.to_s))

  # POST/GET na API da conta (login, casa) → `data`.
  def account(base, path, email:, device_id:, token: nil, method: "POST")
    headers = { "header_clientid" => client_id(email, device_id), "Accept" => "application/json" }
    headers["Authorization"] = token if token
    body = JSON.parse(SafeHttp.request(method, "#{base}#{path}", headers: headers, timeout: 15).body.presence || "{}")
    raise Error, "Roborock: #{body['msg'] || body['code']}" unless body["code"].to_i == 200

    body["data"]
  rescue SafeHttp::Error, JSON::ParserError => e
    raise Error, "Roborock: #{e.message}"
  end

  def hawk(rriot, path)
    ts = Time.now.to_i
    nonce = SecureRandom.urlsafe_base64(6)
    pre = [ rriot["u"], rriot["s"], nonce, ts, Digest::MD5.hexdigest(path), "", "" ].join(":")
    mac = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", rriot["h"].to_s, pre))
    %(Hawk id="#{rriot['u']}", s="#{rriot['s']}", ts="#{ts}", nonce="#{nonce}", mac="#{mac}")
  end

  # Casa → {"devices", "receivedDevices", "products", "rooms"}.
  def home(rriot, home_id)
    path = "/user/homes/#{home_id}"
    res = SafeHttp.request("GET", "#{rriot.dig('r', 'a')}#{path}", headers: { "Authorization" => hawk(rriot, path), "Accept" => "application/json" }, timeout: 15)
    body = JSON.parse(res.body.presence || "{}")
    raise Error, "Roborock: #{body['msg'] || "HTTP #{res.status}"}" unless res.status == 200 && body["success"] != false

    body["result"].to_h
  rescue SafeHttp::Error, JSON::ParserError => e
    raise Error, "Roborock: #{e.message}"
  end

  # --- MQTT -------------------------------------------------------------------
  def mqtt_user(rriot) = Digest::MD5.hexdigest("#{rriot['u']}:#{rriot['k']}")[2, 8]
  def mqtt_pass(rriot) = Digest::MD5.hexdigest("#{rriot['s']}:#{rriot['k']}")[16, 16]
  def endpoint(rriot) = Base64.strict_encode64(Digest::MD5.digest(rriot["k"].to_s)[8, 6])

  # Um pedido JSON-RPC ao robô → `result`.
  # ponytail: uma conexão MQTT por pedido (leitura de minuto em minuto); ouvinte fixo se precisar de evento na hora.
  def rpc(rriot, duid, local_key, method, params = [])
    uri = URI(rriot.dig("r", "m").to_s)
    user = mqtt_user(rriot)
    id = rand(10_000..99_999)
    ts = Time.now.to_i
    inner = { id: id, method: method, params: params, security: { endpoint: endpoint(rriot), nonce: SecureRandom.hex(16) } }
    payload = { dps: { "101" => inner.to_json }, t: ts }.to_json
    MQTT::Client.connect(host: uri.host, port: uri.port || 8883, ssl: %w[ssl mqtts].include?(uri.scheme), username: user, password: mqtt_pass(rriot),
                         client_id: "ma-#{SecureRandom.hex(4)}", keep_alive: 30) do |c|
      c.subscribe("rr/m/o/#{rriot['u']}/#{user}/#{duid}")
      c.publish("rr/m/i/#{rriot['u']}/#{user}/#{duid}", encode(local_key, 101, payload, ts: ts))
      Timeout.timeout(RPC_TIMEOUT) do
        loop do
          _topic, raw = c.get
          protocol, body = decode(local_key, raw)
          next unless protocol == 102

          msg = JSON.parse(JSON.parse(body).dig("dps", "102").to_s)
          next unless msg["id"] == id
          raise Error, "Roborock: #{msg.dig('error', 'message') || msg['error']}" if msg["error"]

          return msg["result"]
        end
      end
    end
  rescue MQTT::Exception, Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError, JSON::ParserError => e
    raise Error, "Roborock: #{e.class.name.demodulize} no MQTT"
  end
end
