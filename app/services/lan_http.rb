require "net/http"

# HTTP dos aparelhos e servidores da rede de casa e das APIs de aparelho
# (integ: Frigate, Reolink, UniFi Protect, WLED, Hue, SwitchBot…): JSON de ida
# e volta, timeout curto, 401/403 = erro de credencial (Reconfigurar) e erro
# de rede vira Integrations::Error (a tela mostra, não dá 500). `insecure`:
# aparelho com certificado próprio (UniFi, Hue), sem conferir a cadeia.
# Não passa pelo SafeHttp de propósito: o endereço é da rede de casa.
module LanHttp
  NET_ERRORS = [ SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError, JSON::ParserError, EOFError, URI::InvalidURIError ].freeze

  module_function

  # → corpo (JSON lido, ou o texto com raw: true). Com bloco, recebe a resposta (cookies).
  def call(method, url, body: nil, headers: {}, raw: false, insecure: false, timeout: 8)
    uri = URI(url)
    req = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
    headers.each { |k, v| req[k] = v }
    if body
      req.body = body.is_a?(String) ? body : body.to_json
      req["Content-Type"] ||= "application/json"
    end
    opts = { use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: timeout }
    opts[:verify_mode] = OpenSSL::SSL::VERIFY_NONE if insecure # aparelho da rede de casa com certificado próprio
    res = Net::HTTP.start(uri.host, uri.port, **opts) { |http| http.request(req) }
    raise Integrations.auth(Integrations::Error.new("#{uri.host} recusou o acesso (#{res.code}): confira usuário, senha ou token.")) if %w[401 403].include?(res.code)
    raise Integrations::Error, "#{uri.host} respondeu #{res.code}." unless res.is_a?(Net::HTTPSuccess)

    yield res if block_given?
    raw ? res.body : (res.body.present? ? JSON.parse(res.body) : {})
  rescue *NET_ERRORS => e
    raise Integrations::Error, "Sem conexão com #{uri&.host || url} (#{e.class.name.demodulize})."
  end

  def get(url, **) = call(:get, url, **)
  def post(url, body = nil, **) = call(:post, url, body: body, **)

  # Endereço base digitado ("192.168.0.5:5000" ou "http://…") → "http://…" sem barra no fim.
  def base(text, scheme: "http")
    t = text.to_s.strip.delete_suffix("/")
    t = "#{scheme}://#{t}" unless t.match?(%r{\Ahttps?://}i)
    URI(t).host.present? ? t : nil
  rescue URI::InvalidURIError
    nil
  end
end
