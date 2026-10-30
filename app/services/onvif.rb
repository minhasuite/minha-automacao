require "net/http"
require "rexml/document"

# Câmera ONVIF na rede local (Profile S/T, SOAP 1.2 com WS-Security
# UsernameToken digest): nome e modelo, perfis de vídeo com o endereço RTSP
# de cada um e os eventos de movimento por PullPoint. É o que o plugin
# "Câmera RTSP / ONVIF" usa para achar os streams (o vídeo segue pelo
# go2rtc) e o `Onvif::Listener` para o movimento. Só leitura: nada aqui
# muda a câmera. Rede local como o Isapi (o SafeHttp barraria o IP interno).
module Onvif
  class Error < Integrations::Error; end

  NS = { "s" => "http://www.w3.org/2003/05/soap-envelope", "tds" => "http://www.onvif.org/ver10/device/wsdl",
         "trt" => "http://www.onvif.org/ver10/media/wsdl", "tt" => "http://www.onvif.org/ver10/schema",
         "tev" => "http://www.onvif.org/ver10/events/wsdl", "wsnt" => "http://docs.oasis-open.org/wsn/b-2",
         "wsa" => "http://www.w3.org/2005/08/addressing" }.freeze
  WSSE = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd".freeze
  WSU = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd".freeze
  DIGEST = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest".freeze
  # Tópicos e itens que querem dizer movimento nas câmeras comuns (regra de
  # movimento da câmera, alarme de movimento da fonte de vídeo).
  MOTION_TOPIC = /motion/i
  MOTION_ITEMS = %w[IsMotion State Motion].freeze

  class Client
    attr_reader :host, :port

    def initialize(host:, port: 80, username: nil, password: nil)
      @host = host
      @port = port.presence || 80
      @username = username
      @password = password
      @offset = 0
    end

    def device_url = "http://#{@host}:#{@port}/onvif/device_service"

    # Acerta o relógio do digest pelo da câmera (relógio errado = senha recusada).
    def sync_clock!
      doc = call(device_url, "<tds:GetSystemDateAndTime/>", auth: false)
      d = ->(n) { text(doc, "//*[local-name()='UTCDateTime']//*[local-name()='#{n}']").to_i }
      cam = Time.utc(d.call("Year"), d.call("Month"), d.call("Day"), d.call("Hour"), d.call("Minute"), d.call("Second"))
      @offset = cam - Time.now.utc if d.call("Year").positive?
      self
    rescue Error
      self # sem hora da câmera: usa a nossa
    end

    def info
      doc = call(device_url, "<tds:GetDeviceInformation/>")
      { "manufacturer" => text(doc, "//*[local-name()='Manufacturer']"), "model" => text(doc, "//*[local-name()='Model']"),
        "serial" => text(doc, "//*[local-name()='SerialNumber']") }
    end

    # {"media" => url, "events" => url ou nil}
    def services
      doc = call(device_url, "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>")
      { "media" => text(doc, "//*[local-name()='Media']/*[local-name()='XAddr']"),
        "events" => text(doc, "//*[local-name()='Events']/*[local-name()='XAddr']") }.transform_values(&:presence)
    end

    # [{"token", "name", "width", "height", "uri"}] (RTSP de cada perfil).
    def profiles(media_url)
      doc = call(media_url, "<trt:GetProfiles/>")
      REXML::XPath.match(doc, "//*[local-name()='Profiles']").map do |p|
        token = p.attributes["token"]
        res = REXML::XPath.first(p, ".//*[local-name()='VideoEncoderConfiguration']/*[local-name()='Resolution']")
        { "token" => token, "name" => text(p, "./*[local-name()='Name']"),
          "width" => res && text(res, "./*[local-name()='Width']").to_i, "height" => res && text(res, "./*[local-name()='Height']").to_i,
          "uri" => stream_uri(media_url, token) }
      end
    end

    def stream_uri(media_url, token)
      body = "<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport>" \
             "</trt:StreamSetup><trt:ProfileToken>#{token.to_s.encode(xml: :text)}</trt:ProfileToken></trt:GetStreamUri>"
      text(call(media_url, body), "//*[local-name()='MediaUri']/*[local-name()='Uri']").presence
    end

    # Assinatura de eventos (PullPoint) → {"url", "headers" (parâmetros de referência a devolver)}.
    def subscribe(events_url, seconds: 600)
      doc = call(events_url, "<tev:CreatePullPointSubscription><tev:InitialTerminationTime>PT#{seconds}S</tev:InitialTerminationTime></tev:CreatePullPointSubscription>")
      ref = REXML::XPath.first(doc, "//*[local-name()='SubscriptionReference']") or raise Error, "A câmera não abriu a assinatura de eventos."
      params = REXML::XPath.first(ref, "./*[local-name()='ReferenceParameters']")
      { "url" => text(ref, "./*[local-name()='Address']"), "headers" => params ? params.children.map(&:to_s).join : "" }
    end

    # Mensagens de movimento desde a última vez → [true/false, ...] em ordem.
    def pull(sub, timeout: 20)
      body = "<tev:PullMessages><tev:Timeout>PT#{timeout}S</tev:Timeout><tev:MessageLimit>20</tev:MessageLimit></tev:PullMessages>"
      Onvif.motions(call(sub["url"], body, headers: sub["headers"], action: "http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest",
                                          read_timeout: timeout + 10))
    end

    def renew(sub, seconds: 600)
      call(sub["url"], "<wsnt:Renew><wsnt:TerminationTime>PT#{seconds}S</wsnt:TerminationTime></wsnt:Renew>", headers: sub["headers"])
    end

    def unsubscribe(sub)
      call(sub["url"], "<wsnt:Unsubscribe/>", headers: sub["headers"])
    rescue Error
      nil
    end

    def call(url, body, auth: true, headers: nil, action: nil, read_timeout: 10)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/soap+xml; charset=utf-8#{"; action=\"#{action}\"" if action}"
      req.body = envelope(body, auth: auth, headers: headers, to: (url if headers))
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: read_timeout) { |h| h.request(req) }
      doc = REXML::Document.new(res.body.to_s)
      fault = text(doc, "//*[local-name()='Fault']//*[local-name()='Text']").presence
      raise Integrations.auth(Error.new("A câmera recusou usuário ou senha.")) if res.code == "401" || fault.to_s.match?(/auth|password|not authorized|sender not/i)
      raise Error, "A câmera respondeu #{res.code}#{": #{fault}" if fault}." unless res.is_a?(Net::HTTPSuccess)

      doc
    rescue REXML::ParseException
      raise Error, "Resposta ONVIF ilegível."
    rescue SystemCallError, SocketError, Timeout::Error, IOError => e
      raise Error, "Sem conexão com #{uri&.host} (#{e.class.name.demodulize})."
    end

    private

    def envelope(body, auth:, headers:, to:)
      ns = NS.map { |k, v| %(xmlns:#{k}="#{v}") }.join(" ")
      head = [ (security if auth && @username.present?), (%(<wsa:To>#{to.encode(xml: :text)}</wsa:To>) if to), headers.presence ].compact.join
      %(<?xml version="1.0" encoding="UTF-8"?><s:Envelope #{ns}><s:Header>#{head}</s:Header><s:Body>#{body}</s:Body></s:Envelope>)
    end

    # PasswordDigest = Base64(SHA1(nonce + created + senha)).
    def security
      nonce = SecureRandom.random_bytes(16)
      created = (Time.now.utc + @offset).strftime("%Y-%m-%dT%H:%M:%SZ")
      digest = Base64.strict_encode64(Digest::SHA1.digest(nonce + created + @password.to_s))
      %(<wsse:Security s:mustUnderstand="1" xmlns:wsse="#{WSSE}" xmlns:wsu="#{WSU}"><wsse:UsernameToken>) +
        %(<wsse:Username>#{@username.to_s.encode(xml: :text)}</wsse:Username><wsse:Password Type="#{DIGEST}">#{digest}</wsse:Password>) +
        %(<wsse:Nonce>#{Base64.strict_encode64(nonce)}</wsse:Nonce><wsu:Created>#{created}</wsu:Created></wsse:UsernameToken></wsse:Security>)
    end

    def text(node, path) = REXML::XPath.first(node, path)&.text.to_s.strip
  end

  module_function

  # Caminho + consulta de um endereço RTSP (URI genérica não tem request_uri).
  def path_of(uri) = "#{uri.path.presence || '/'}#{"?#{uri.query}" if uri.query}"

  # Movimento nas mensagens de evento: tópico com "motion" e um item booleano conhecido.
  def motions(doc)
    REXML::XPath.match(doc, "//*[local-name()='NotificationMessage']").map do |m|
      next unless REXML::XPath.first(m, ".//*[local-name()='Topic']")&.text.to_s.match?(MOTION_TOPIC)

      item = REXML::XPath.match(m, ".//*[local-name()='Data']/*[local-name()='SimpleItem']").find { |i| MOTION_ITEMS.include?(i.attributes["Name"]) }
      item.attributes["Value"].to_s.casecmp?("true") if item
    end.compact # false conta (parou o movimento); nil = outro evento
  end

  # Câmera → entrada do inventário: um aparelho `go2rtc` com um ponto
  # `stream` por perfil e, se houver eventos, um ponto `motion`.
  def inventory(settings, password)
    client = Client.new(host: settings["host"], port: settings["onvif_port"], username: settings["username"], password: password).sync_clock!
    info = client.info
    svc = client.services
    raise Error, "A câmera não informou o serviço de vídeo (ONVIF Media)." unless svc["media"]

    streams = client.profiles(svc["media"]).select { |p| p["uri"] }
    raise Error, "Nenhum perfil de vídeo com endereço RTSP." if streams.empty?

    rtsp = URI(streams.first["uri"])
    points = streams.map do |p|
      u = URI(p["uri"])
      size = "#{p['width']}x#{p['height']}" if p["width"].to_i.positive?
      { "name" => [ p["name"].presence || "Vídeo", size ].compact.join(" "), "capability" => "stream", "history" => "none",
        "address" => { "path" => path_of(u), "port" => (u.port if u.port != rtsp.port) }.compact }
    end
    points << { "name" => "Movimento", "capability" => "motion", "device_class" => "motion", "address" => { "onvif" => "motion" } } if svc["events"]
    # id pelo IP: câmera barata repete o número de série (ex.: 123456).
    { "id" => "onvif:#{settings['host']}", "kind" => "go2rtc", "name" => settings["name"].presence || [ info["manufacturer"], info["model"] ].compact_blank.join(" ").presence || "Câmera #{settings['host']}",
      "manufacturer" => info["manufacturer"], "model" => info["model"], "category" => "Câmera ONVIF", "online" => true,
      "address" => { "host" => rtsp.host, "port" => rtsp.port, "username" => settings["username"].presence, "onvif_port" => client.port.to_i }.compact,
      "points" => points }
  end
end
