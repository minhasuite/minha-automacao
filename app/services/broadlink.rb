require "socket"
require "openssl"

# Broadlink (RM mini, RM4, RM Pro) pela rede local, como o python-broadlink
# (Pacote 1): UDP 80, cabeçalho de 0x38 bytes com checksum (soma + 0xBEAF),
# corpo em AES-128-CBC com a chave de fábrica até o `auth` (0x65) devolver a
# chave da sessão. Comandos do controle (pacote 0x6A): enviar (0x02),
# aprender (0x03), ler o aprendido (0x04) e sensores do RM4 (0x24).
# Modelos (tipo do aparelho → nome, quadro com tamanho, sensores) são dados em
# config/device_maps/broadlink.yml. Descoberta = "hello" (0x06), só lê.
module Broadlink
  class Error < StandardError; end

  KEY = [ "097628343fe99e23765c1513accf8b02" ].pack("H*").freeze
  IV = [ "562e17996d093d28ddb3ba695a2e6f58" ].pack("H*").freeze
  MAGIC = [ "5aa5aa555aa5aa55" ].pack("H*").freeze
  PORT = 80
  MAP = YAML.load_file(Rails.root.join("config/device_maps/broadlink.yml")).freeze

  module_function

  def checksum(bytes) = (bytes.sum + 0xBEAF) & 0xFFFF

  def cipher(mode, key, data)
    c = OpenSSL::Cipher.new("aes-128-cbc").tap { |x| x.public_send(mode) }
    c.key = key
    c.iv = IV
    c.padding = 0
    c.update(data) + c.final
  end

  def encrypt(key, data) = cipher(:encrypt, key, data + ("\0" * ((16 - (data.bytesize % 16)) % 16)))
  def decrypt(key, data) = data.empty? ? data : cipher(:decrypt, key, data)

  # Modelo pelo tipo do aparelho; desconhecido usa o quadro do RM4 se o tipo for novo.
  # ponytail: tipo fora do mapa decide pelo número (>= 0x5100 = família RM4); acrescente no YAML.
  def model(devtype)
    MAP["models"][format("0x%04x", devtype)] || { "name" => "Broadlink #{format('0x%04x', devtype)}", "framed" => devtype >= 0x5100 }
  end

  def hello_packet
    packet = ("\0" * 0x30).b
    packet.setbyte(0x26, 0x06)
    sum = checksum(packet.bytes)
    packet[0x20, 2] = [ sum ].pack("v")
    packet
  end

  # Resposta do hello → {host, mac (hex), devtype, name, locked}.
  def parse_hello(data, host)
    return if data.bytesize < 0x40

    { "host" => host, "devtype" => data.byteslice(0x34, 2).unpack1("v"), "mac" => data.byteslice(0x3a, 6).reverse.unpack1("H*"),
      "name" => data.byteslice(0x40, 64).to_s.split("\0").first.to_s.dup.force_encoding("UTF-8").scrub, "locked" => data.bytesize > 0x7f && data.getbyte(-1) == 1 }
  end

  # Só lê: "hello" em broadcast (e a cada IP de MDNS_SUBNET, que o container
  # da bridge não alcança o broadcast da casa) → aparelhos que responderam.
  def discover(timeout: 2.0, targets: Mdns.targets(ENV["MDNS_SUBNET"].presence), port: PORT)
    sock = UDPSocket.new
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true)
    [ "255.255.255.255", *targets ].each { |ip| sock.send(hello_packet, 0, ip, port) rescue nil } # rubocop:disable Style/RescueModifier -- IP que não responde não importa
    Mdns.collect(sock, timeout).filter_map { |data, ip| parse_hello(data, ip) }.uniq { |d| d["mac"] }
  ensure
    sock&.close
  end

  # Hello direto num IP (assistente com o IP digitado).
  def hello(host, port = PORT, timeout: 3)
    sock = UDPSocket.new
    sock.send(hello_packet, 0, host, port)
    raise Error, "O aparelho não respondeu em #{host}." unless sock.wait_readable(timeout)

    parse_hello(sock.recvfrom(2048).first, host) or raise Error, "Resposta estranha de #{host}."
  ensure
    sock&.close
  end

  class Client
    LEARN_S = 20

    def initialize(host:, mac:, devtype:, port: PORT, timeout: 5)
      @host = host
      @port = port
      @mac = [ mac ].pack("H*").reverse
      @devtype = devtype
      @timeout = timeout
      @key = KEY
      @id = 0
      @count = rand(0x8000)
    end

    def model = Broadlink.model(@devtype)

    def auth!
      payload = ("\0" * 0x50).b
      payload[0x04, 16] = "1" * 16
      payload.setbyte(0x1e, 0x01)
      payload.setbyte(0x2d, 0x01)
      payload[0x30, 6] = "Test 1"
      resp = send_packet(0x65, payload)
      @id = resp.byteslice(0, 4).unpack1("V")
      @key = resp.byteslice(4, 16)
      self
    end

    def send_data(code) = command(0x02, code)

    # Aprendizado: entra, pergunta a cada segundo até `timeout`; código cru ou nil.
    def learn(timeout: LEARN_S, interval: 1)
      command(0x03)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep interval
        code = check_data
        return code if code.present?
      end
      nil
    end

    # Código aprendido, ou nil enquanto nada chegou (o aparelho responde erro).
    def check_data
      command(0x04)
    rescue Error
      nil
    end

    # RM4 com cabo de sensor: {temperature, humidity}.
    def sensors
      d = command(0x24)
      t = d.byteslice(0, 2).unpack("cc")
      { "temperature" => (t[0] + (t[1] / 100.0)).round(1), "humidity" => (d.getbyte(2) + (d.getbyte(3) / 100.0)).round(1) }
    end

    # Comando do controle (0x6A): RM4 leva o tamanho na frente e responde com ele.
    def command(cmd, data = "".b)
      framed = model["framed"]
      payload = framed ? [ data.bytesize + 4, cmd ].pack("vV") + data.b : [ cmd ].pack("V") + data.b
      resp = send_packet(0x6a, payload)
      return resp.byteslice(4..) unless framed

      len = resp.byteslice(0, 2).unpack1("v")
      resp.byteslice(6, len - 4) || "".b
    end

    def send_packet(type, payload)
      @count = (@count + 1) & 0xFFFF
      packet = ("\0" * 0x38).b
      packet[0, 8] = MAGIC
      packet[0x24, 6] = [ @devtype, type, @count ].pack("vvv")
      packet[0x2a, 6] = @mac
      packet[0x30, 4] = [ @id ].pack("V")
      packet[0x34, 2] = [ Broadlink.checksum(payload.bytes) ].pack("v")
      packet << Broadlink.encrypt(@key, payload.b)
      packet[0x20, 2] = [ Broadlink.checksum(packet.bytes) ].pack("v")
      parse(exchange(packet))
    end

    private

    def exchange(packet)
      sock = UDPSocket.new
      sock.send(packet, 0, @host, @port)
      raise Error, "O Broadlink não respondeu (#{@host})." unless sock.wait_readable(@timeout)

      sock.recvfrom(4096).first
    rescue SystemCallError, SocketError => e
      raise Error, "Sem conexão com o Broadlink #{@host}: #{e.message}"
    ensure
      sock&.close
    end

    def parse(resp)
      raise Error, "Resposta curta do Broadlink." if resp.bytesize < 0x38

      sum = resp.byteslice(0x20, 2).unpack1("v")
      check = resp.dup
      check[0x20, 2] = "\0\0"
      raise Error, "Checksum errado na resposta do Broadlink." unless Broadlink.checksum(check.bytes) == sum

      err = resp.byteslice(0x22, 2).unpack1("s<")
      raise Error, err == -7 ? "Aparelho bloqueado: desbloqueie no app Broadlink." : "Broadlink recusou (erro #{err})." unless err.zero?

      Broadlink.decrypt(@key, resp.byteslice(0x38..))
    end
  end
end
