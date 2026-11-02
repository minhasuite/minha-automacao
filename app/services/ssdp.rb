require "socket"

# Descoberta por SSDP/UPnP (produto: TVs LG e Samsung, como o mDNS do Mdns).
# Só lê: manda um M-SEARCH pelo tipo (`ST`) e junta as respostas por
# `timeout` segundos. Mesmo formato do Mdns.browse.
module Ssdp
  ADDR = "239.255.255.250".freeze
  PORT = 1900

  module_function

  # → [{"name", "host", "port", "txt" => {"st", "server", "location"}}], um por IP.
  def search(st, timeout: 2.0)
    sock = UDPSocket.new
    sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_MULTICAST_TTL, 4)
    sock.send(request(st), 0, ADDR, PORT)
    parse_all(Mdns.collect(sock, timeout))
  rescue SystemCallError => e
    Rails.logger.info("[ssdp] #{e.message}")
    []
  ensure
    sock&.close
  end

  def request(st) = "M-SEARCH * HTTP/1.1\r\nHOST: #{ADDR}:#{PORT}\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: #{st}\r\n\r\n"

  # Pacotes [dados, ip] → aparelhos (o primeiro de cada IP).
  def parse_all(packets)
    packets.filter_map { |data, ip| parse(data, ip) }.uniq { |s| s["host"] }
  end

  def parse(data, ip)
    lines = data.to_s.scrub.split("\r\n")
    return unless lines.first.to_s.match?(%r{\AHTTP/1\.\d 200}i)

    h = lines.drop(1).filter_map { |l| l.split(":", 2).then { |k, v| [ k.strip.downcase, v.to_s.strip ] if v } }.to_h
    port = h["location"].to_s[%r{\Ahttps?://[^/:]+:(\d+)}, 1]&.to_i
    { "name" => h["server"].presence || ip, "host" => ip, "port" => port,
      "txt" => { "st" => h["st"], "server" => h["server"], "location" => h["location"] }.compact }
  end
end
