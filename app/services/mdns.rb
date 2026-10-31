require "resolv"
require "socket"
require "ipaddr"

# Descoberta por mDNS/DNS-SD (Pacote 1: ESPHome, Shelly, Chromecast…). Só
# lê: manda a pergunta PTR do serviço e junta as respostas por `timeout`
# segundos. Nada é cadastrado aqui; o plugin mostra a lista e a pessoa
# escolhe. Pergunta por multicast (224.0.0.251:5353, pedindo resposta
# unicast) e, se `MDNS_SUBNET` estiver no servidor (ex.: 192.168.68.0/24),
# também uma pergunta unicast a cada IP da faixa (RFC 6762 §6.7): o
# container na rede bridge do Docker não alcança o multicast da casa.
module Mdns
  ADDR = "224.0.0.251".freeze
  PORT = 5353
  IN = Resolv::DNS::Resource::IN

  module_function

  # → [{"name", "host", "port", "txt" => {chave → valor}}], sem repetir instância.
  def browse(service, timeout: 2.0, subnet: ENV["MDNS_SUBNET"].presence)
    type = "#{service}.local"
    sock = UDPSocket.new
    sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_MULTICAST_TTL, 255)
    q = query(type)
    begin
      sock.send(q, 0, ADDR, PORT)
    rescue SystemCallError => e
      Rails.logger.info("[mdns] multicast: #{e.message}")
    end
    targets(subnet).each { |ip| sock.send(q, 0, ip, PORT) rescue nil } # rubocop:disable Style/RescueModifier -- IP que não responde não importa
    parse_all(type, collect(sock, timeout))
  ensure
    sock&.close
  end

  # Pergunta PTR com o bit QU (resposta unicast).
  def query(type)
    msg = Resolv::DNS::Message.new(0)
    msg.add_question(type, IN::PTR)
    bytes = msg.encode
    bytes.setbyte(bytes.bytesize - 2, bytes.getbyte(bytes.bytesize - 2) | 0x80)
    bytes
  end

  def targets(subnet)
    return [] if subnet.blank?

    range = IPAddr.new(subnet).to_range
    return [] if range.count > 1024 # só uma rede de casa

    range.map(&:to_s).reject { |ip| ip.end_with?(".0", ".255") }
  rescue IPAddr::Error
    []
  end

  def collect(sock, timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    packets = []
    loop do
      left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if left <= 0
      next unless sock.wait_readable(left)

      data, from = sock.recvfrom(9000)
      packets << [ data, from[3] ]
    end
    packets
  end

  # Pacotes [dados, ip de origem] → serviços encontrados.
  def parse_all(type, packets)
    found = {}
    packets.each do |data, ip|
      parse(type, data, ip).each { |s| found[s["name"]] ||= s }
    rescue Resolv::DNS::DecodeError
      next
    end
    found.values.sort_by { |s| s["name"].downcase }
  end

  def parse(type, data, ip)
    msg = Resolv::DNS::Message.decode(data)
    records = (msg.answer + msg.additional).map { |name, _ttl, rr| [ name.to_s, rr ] }
    instances = records.filter_map { |name, rr| rr.name.to_s if rr.is_a?(IN::PTR) && name.casecmp?(type) }
    instances.map do |inst|
      srv = records.find { |n, rr| n == inst && rr.is_a?(IN::SRV) }&.last
      txt = records.find { |n, rr| n == inst && rr.is_a?(IN::TXT) }&.last
      addr = srv && records.find { |n, rr| n == srv.target.to_s && rr.is_a?(IN::A) }&.last
      { "name" => inst.delete_suffix(".#{type}"), "host" => addr&.address&.to_s || ip, "port" => srv&.port,
        "txt" => Array(txt&.strings).to_h { |s| s.split("=", 2).then { |k, v| [ k, v.to_s ] } } }
    end
  end
end
