# Sonda do host (ondaA2 A13/A19): roda num container de uma vez só, criado
# pelo supervisor com a rede do host e /dev, /sys e /etc do host só leitura
# em /host. Só lê e imprime um JSON: sistema, memória, rede, vizinhos (ARP com
# o nome do DHCP pelo DNS reverso do roteador), portas seriais e USB.
require "json"
require "socket"
require "resolv"
require "etc"

module HostProbe
  module_function

  def read(path)
    File.read(path)
  rescue SystemCallError
    nil
  end

  def run(root = "/host")
    { hostname: read("#{root}/etc/hostname").to_s.strip, os: read("#{root}/etc/os-release").to_s[/^PRETTY_NAME="?([^"\n]*)/, 1],
      kernel: read("/proc/sys/kernel/osrelease").to_s.strip, arch: Etc.uname[:machine],
      cpu: read("/proc/cpuinfo").to_s[/^model name\s*:\s*(.+)$/, 1], cpus: Etc.nprocessors,
      memory_mb: meminfo("MemTotal"), memory_free_mb: meminfo("MemAvailable"), uptime_s: read("/proc/uptime").to_s.to_f.round,
      interfaces: interfaces(root), gateway: gateway, dns: (read("#{root}/etc/resolv.conf") || read("/etc/resolv.conf")).to_s.scan(/^nameserver\s+(\S+)/).flatten,
      neighbors: neighbors, serial: serial(root), usb: usb(root) }
  end

  def meminfo(key) = read("/proc/meminfo").to_s[/^#{key}:\s+(\d+)/, 1].to_i / 1024

  VIRTUAL = /\A(lo|veth|docker|br-|virbr|tun|tap)/

  def interfaces(root)
    Socket.getifaddrs.group_by(&:name).reject { |name, _| name.match?(VIRTUAL) }.map do |name, list|
      ips = list.filter_map(&:addr).select(&:ip?)
      { name: name, mac: read("#{root}/sys/class/net/#{name}/address").to_s.strip, state: read("#{root}/sys/class/net/#{name}/operstate").to_s.strip,
        ipv4: ips.select(&:ipv4?).map(&:ip_address), ipv6: ips.select(&:ipv6?).map { |a| a.ip_address.sub(/%.*/, "") } }
    end
  end

  # /proc/net/route: destino 00000000 = rota padrão; o gateway vem em hexa little-endian.
  def gateway
    hex = read("/proc/net/route").to_s.lines.drop(1).map(&:split).find { |c| c[1] == "00000000" }&.dig(2) or return nil
    [ hex ].pack("H*").unpack("C4").reverse.join(".")
  end

  def neighbors
    rows = read("/proc/net/arp").to_s.lines.drop(1).map(&:split).select { |c| c[3] && c[3] != "00:00:00:00:00:00" }
    dns = Resolv::DNS.new.tap { |d| d.timeouts = 0.7 }
    rows.first(254).map { |c| Thread.new { { ip: c[0], mac: c[3].upcase, hostname: (dns.getname(c[0]).to_s rescue nil) } } }.map(&:value)
  end

  # Sobe a árvore do sysfs até achar o aparelho USB (idVendor).
  def usb_dir(path)
    dir = File.realpath(path)
    4.times do
      return dir if File.exist?("#{dir}/idVendor")

      dir = File.dirname(dir)
    end
    nil
  rescue SystemCallError
    nil
  end

  def usb_info(dir)
    return {} unless dir

    { vid: read("#{dir}/idVendor").to_s.strip.upcase, pid: read("#{dir}/idProduct").to_s.strip.upcase,
      manufacturer: read("#{dir}/manufacturer").to_s.strip, product: read("#{dir}/product").to_s.strip }
  end

  def serial(root)
    Dir["#{root}/dev/serial/by-id/*"].sort.map do |link|
      tty = File.basename(File.readlink(link)) rescue nil
      { id: File.basename(link), path: "/dev/serial/by-id/#{File.basename(link)}", tty: tty && "/dev/#{tty}" }
        .merge(usb_info(tty && usb_dir("#{root}/sys/class/tty/#{tty}/device")))
    end
  end

  def usb(root)
    Dir["#{root}/sys/bus/usb/devices/*/idVendor"].sort.map { |f| usb_info(File.dirname(f)) }.reject { |u| u[:product].empty? && u[:manufacturer].empty? }
  end
end

puts JSON.generate(HostProbe.run) if $PROGRAM_NAME == __FILE__
