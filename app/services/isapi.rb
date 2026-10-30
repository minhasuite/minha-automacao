require "net/http"
require "rexml/document"

# DVR/NVR/câmera Hikvision pela ISAPI (HTTP com Digest na rede local): lê o
# nome, o modelo e os canais de vídeo e devolve UM aparelho `go2rtc` com um
# ponto `stream` por canal, no substream (x02), que é o que o go2rtc toca sem
# quebrar no DVR daqui. Só leitura. Integração `hikvision`: settings {host,
# http_port, username}, senha nas credenciais.
module Isapi
  class Error < Integrations::Error; end

  module_function

  def inventory(integration)
    s = integration.settings
    password = integration.secrets["password"]
    info = xml(get(s, password, "/ISAPI/System/deviceInfo"))
    channels = xml(get(s, password, "/ISAPI/Streaming/channels"))
    streams = channels.get_elements("//StreamingChannel").filter_map do |c|
      id = c.elements["id"]&.text.to_s
      next unless id.end_with?("02") && c.elements["enabled"]&.text != "false"

      name = c.elements["channelName"]&.text.to_s.squish.presence || "Câmera #{id.to_i / 100}"
      { "name" => name, "capability" => "stream", "history" => "none", "address" => { "path" => "/Streaming/Channels/#{id}" } }
    end
    [ { "id" => s["host"], "kind" => "go2rtc", "match" => "host", "name" => info.elements["//deviceName"]&.text.to_s.squish.presence || "DVR #{s['host']}",
        "manufacturer" => "Hikvision", "model" => info.elements["//model"]&.text, "category" => "#{streams.size} canais",
        "online" => true, "address" => { "host" => s["host"], "port" => 554, "username" => s["username"] }, "points" => streams } ]
  end

  def xml(body) = REXML::Document.new(body.sub(/\sxmlns="[^"]*"/, ""))

  # GET com Digest (o padrão da Hikvision); 401 depois do desafio = senha errada.
  def get(settings, password, path)
    uri = URI("http://#{settings['host']}:#{settings['http_port'].presence || 80}#{path}")
    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 15) do |http|
      res = http.request(Net::HTTP::Get.new(uri))
      if res.code == "401" && res["www-authenticate"].to_s.start_with?("Digest")
        req = Net::HTTP::Get.new(uri)
        req["Authorization"] = digest(res["www-authenticate"], settings["username"], password, path)
        res = http.request(req)
      end
      raise Integrations.auth(Error.new("Usuário ou senha do DVR não conferem.")) if res.code == "401"
      raise Error, "O DVR respondeu #{res.code}." unless res.is_a?(Net::HTTPSuccess)

      res.body
    end
  rescue SystemCallError, SocketError, Timeout::Error, IOError => e
    raise Error, "Sem conexão com #{settings['host']} (#{e.class.name.demodulize})."
  end

  def digest(challenge, user, password, path)
    p = challenge.sub(/\ADigest\s+/, "").scan(/(\w+)="?([^",]*)"?/).to_h
    cnonce = SecureRandom.hex(8)
    ha1 = Digest::MD5.hexdigest("#{user}:#{p['realm']}:#{password}")
    ha2 = Digest::MD5.hexdigest("GET:#{path}")
    qop = p["qop"].to_s.split(",").map(&:strip).include?("auth") ? "auth" : nil
    response = Digest::MD5.hexdigest([ ha1, p["nonce"], *([ "00000001", cnonce, qop ] if qop), ha2 ].join(":"))
    parts = { username: user, realm: p["realm"], nonce: p["nonce"], uri: path, response: response, opaque: p["opaque"] }
    parts.merge!(qop: qop, nc: "00000001", cnonce: cnonce) if qop
    "Digest " + parts.compact.map { |k, v| k.in?(%i[qop nc]) ? "#{k}=#{v}" : %(#{k}="#{v}") }.join(", ")
  end
end
