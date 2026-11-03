require "cgi"

# UPnP/DLNA na rede de casa (ondaC2): ação SOAP num serviço, descrição do
# aparelho (serviços e controlURL) e o ContentDirectory (navegar biblioteca de
# servidor DLNA e de caixa que expõe favoritos, como o Sonos). Rede local
# pelo LanHttp (o SafeHttp barraria o IP interno).
module Upnp
  DIDL_ITEM = %r{<(item|container)\b([^>]*)>(.*?)</\1>}m

  module_function

  def soap(url, service, action, args = {})
    xml = args.map { |k, v| "<#{k}>#{CGI.escapeHTML(v.to_s)}</#{k}>" }.join
    urn = "urn:schemas-upnp-org:service:#{service}:1"
    body = %(<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ) +
           %(s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:#{action} xmlns:u="#{urn}">#{xml}</u:#{action}></s:Body></s:Envelope>)
    LanHttp.post(url, body, raw: true, headers: { "Content-Type" => 'text/xml; charset="utf-8"', "SOAPACTION" => "#{urn}##{action}" })
  end

  def tag(xml, name) = (m = xml.to_s.match(%r{<(?:\w+:)?#{name}\b[^>]*>(.*?)</(?:\w+:)?#{name}>}m)) && CGI.unescapeHTML(m[1])
  def attr(attrs, name) = attrs.to_s[/\b#{name}="([^"]*)"/, 1]&.then { |v| CGI.unescapeHTML(v) }

  # Descrição do aparelho → {"udn", "name", "model", "manufacturer", "services" => {"AVTransport" => controlURL absoluta, ...}}.
  def describe(location)
    xml = LanHttp.get(location, raw: true).to_s
    base = location[%r{\Ahttps?://[^/]+}]
    services = xml.scan(%r{<service>(.*?)</service>}m).to_h do |(s)|
      [ tag(s, "serviceType").to_s[/service:(\w+):/, 1], URI.join("#{base}/", tag(s, "controlURL").to_s).to_s ]
    end
    { "udn" => tag(xml, "UDN").to_s.delete_prefix("uuid:"), "name" => tag(xml, "friendlyName"), "model" => tag(xml, "modelName"),
      "manufacturer" => tag(xml, "manufacturer"), "services" => services.compact }
  end

  # ContentDirectory Browse → [{"id", "title", "container", "class", "url", "mime", "art", "meta"}].
  def browse(control_url, object_id, metadata: false, limit: 200)
    res = soap(control_url, "ContentDirectory", "Browse", "ObjectID" => object_id, "BrowseFlag" => metadata ? "BrowseMetadata" : "BrowseDirectChildren",
                                                          "Filter" => "*", "StartingIndex" => 0, "RequestedCount" => limit, "SortCriteria" => "")
    didl(tag(res, "Result"))
  end

  def didl(xml)
    xml.to_s.scan(DIDL_ITEM).map do |kind, attrs, inner|
      res = inner.match(%r{<res\b([^>]*)>(.*?)</res>}m)
      { "id" => attr(attrs, "id"), "title" => tag(inner, "title"), "container" => kind == "container", "class" => tag(inner, "class"),
        "url" => res && CGI.unescapeHTML(res[2].strip), "mime" => res && attr(res[1], "protocolInfo").to_s.split(":")[2],
        "art" => tag(inner, "albumArtURI"), "meta" => tag(inner, "resMD") }.compact
    end
  end
end
