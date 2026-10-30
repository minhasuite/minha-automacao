require "ipaddr"
require "net/http"
require "resolv"

# HTTP de saída para endereço que o usuário digitou (ação "Chamar HTTP",
# agenda ICS): só http/https, IP privado/local bloqueado por padrão (SSRF),
# conexão presa ao IP checado (sem DNS rebinding) e redirect checado de novo
# a cada salto. Liberação opcional por instalação: `Tenant#http_allow`
# (host exato ou faixa CIDR, "192.168.68.0/24").
module SafeHttp
  class Error < StandardError; end
  class Blocked < Error; end

  BLOCKED = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.168.0.0/16
               198.18.0.0/15 224.0.0.0/3 ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8].map { |c| IPAddr.new(c) }.freeze
  METHODS = %w[GET POST PUT PATCH DELETE].freeze
  MAX_REDIRECTS = 3
  MAX_BODY = 2.megabytes

  Response = Data.define(:status, :body, :headers)

  module_function

  # → Response. Levanta Blocked (endereço interno) ou Error (rede, timeout, resposta grande).
  def request(method, url, headers: {}, body: nil, timeout: 10, allow: current_allow, redirects: MAX_REDIRECTS)
    method = method.to_s.upcase
    raise Error, "Método inválido." unless METHODS.include?(method)

    uri = URI.parse(url.to_s.strip)
    raise Error, "Endereço precisa começar com http:// ou https://." unless uri.is_a?(URI::HTTP) && uri.host.present?

    ip = check!(uri.host, allow)
    res = perform(uri, ip, method, headers, body, timeout)
    if res.is_a?(Net::HTTPRedirection) && res["location"].present?
      raise Error, "Redirecionamentos demais." if redirects.zero?

      next_method = res.code == "307" || res.code == "308" ? method : "GET"
      return request(next_method, uri.merge(res["location"]).to_s, headers: headers, body: (body if next_method == method),
                                                                   timeout: timeout, allow: allow, redirects: redirects - 1)
    end
    Response.new(status: res.code.to_i, body: res.body.to_s, headers: res.to_hash)
  rescue URI::InvalidURIError
    raise Error, "Endereço inválido."
  rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, EOFError, IOError => e
    raise Error, "Falha na conexão: #{e.message.truncate(120)}"
  end

  def get(url, **) = request("GET", url, **)

  # IP que a conexão vai usar (o primeiro); Blocked se algum for interno e não liberado.
  def check!(host, allow = current_allow)
    ips = addresses(host)
    raise Error, "Não achei o endereço #{host}." if ips.empty?

    ips.each { |ip| raise Blocked, "Endereço interno bloqueado (#{host}). Libere em Configurações → Sistema." if blocked?(host, ip, allow) }
    ips.first
  end

  def blocked?(host, ip, allow)
    addr = IPAddr.new(ip)
    addr = addr.native if addr.ipv4_mapped?
    return false unless BLOCKED.any? { |r| r.include?(addr) }

    Array(allow).none? { |rule| rule.casecmp?(host) || (cidr(rule)&.include?(addr)) }
  end

  def cidr(rule)
    IPAddr.new(rule)
  rescue IPAddr::Error
    nil
  end

  def addresses(host)
    host = host.delete_prefix("[").delete_suffix("]")
    IPAddr.new(host) && [ host ]
  rescue IPAddr::Error
    lookup(host)
  end

  # DNS (separado para os specs).
  def lookup(host) = Resolv.getaddresses(host).uniq

  def current_allow = ActsAsTenant.current_tenant.try(:http_allow) || []

  def perform(uri, ip, method, headers, body, timeout)
    http = Net::HTTP.new(uri.host, uri.port)
    http.ipaddr = ip
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = timeout
    http.read_timeout = timeout
    http.write_timeout = timeout
    req = Net::HTTPGenericRequest.new(method, !body.nil?, method != "HEAD", uri.request_uri)
    headers.each { |k, v| req[k] = v }
    req["User-Agent"] ||= "MinhaAutomacao/1.0"
    req.body = body unless body.nil?
    res = http.request(req)
    raise Error, "Resposta grande demais." if res.body.to_s.bytesize > MAX_BODY

    res
  end
end
