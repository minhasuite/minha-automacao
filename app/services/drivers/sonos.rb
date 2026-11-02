require "cgi"

module Drivers
  # Sonos (integ2): caixa pela UPnP local (HTTP 1400, SOAP): o que toca
  # (AVTransport), volume e mudo (RenderingControl). Ponto `media` comum
  # (Drivers::MediaLan). Comando vai para a caixa que recebeu (num grupo, o
  # Sonos repassa ao coordenador o tocar/pausar).
  class Sonos < MediaLan
    PORT = 1400
    SUPPORTS = %w[resume pause next previous volume volume_up volume_down mute play_media].freeze
    STATES = { "PLAYING" => "playing", "PAUSED_PLAYBACK" => "paused", "STOPPED" => "idle", "TRANSITIONING" => "playing" }.freeze
    SERVICES = { "AVTransport" => "/MediaRenderer/AVTransport/Control", "RenderingControl" => "/MediaRenderer/RenderingControl/Control" }.freeze
    ACTIONS = {
      "resume" => [ "AVTransport", "Play", { "Speed" => 1 } ], "pause" => [ "AVTransport", "Pause", {} ],
      "next" => [ "AVTransport", "Next", {} ], "previous" => [ "AVTransport", "Previous", {} ]
    }.freeze

    class << self
      def base(host, port) = "http://#{host}:#{port}"

      # Ação SOAP → corpo da resposta (texto).
      def soap(host, port, service, action, args = {})
        fields = { "InstanceID" => 0 }.merge(service == "RenderingControl" ? { "Channel" => "Master" } : {}).merge(args)
        xml = fields.map { |k, v| "<#{k}>#{CGI.escapeHTML(v.to_s)}</#{k}>" }.join
        body = %(<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ) +
               %(s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:#{action} xmlns:u="urn:schemas-upnp-org:service:#{service}:1">) +
               %(#{xml}</u:#{action}></s:Body></s:Envelope>)
        LanHttp.post("#{base(host, port)}#{SERVICES.fetch(service)}", body, raw: true,
                     headers: { "Content-Type" => 'text/xml; charset="utf-8"', "SOAPACTION" => "urn:schemas-upnp-org:service:#{service}:1##{action}" })
      end

      def tag(xml, name) = (m = xml.to_s.match(%r{<(?:\w+:)?#{name}>(.*?)</(?:\w+:)?#{name}>}m)) && CGI.unescapeHTML(m[1])

      def description(host, port)
        xml = LanHttp.get("#{base(host, port)}/xml/device_description.xml", raw: true)
        { "udn" => tag(xml, "UDN").to_s.delete_prefix("uuid:"), "room" => tag(xml, "roomName"), "model" => tag(xml, "modelName"), "serial" => tag(xml, "serialNum") }
      end

      def read(device)
        h, p = host(device), port(device, PORT)
        state = tag(soap(h, p, "AVTransport", "GetTransportInfo"), "CurrentTransportState")
        meta = tag(soap(h, p, "AVTransport", "GetPositionInfo"), "TrackMetaData").to_s
        vol = tag(soap(h, p, "RenderingControl", "GetVolume"), "CurrentVolume")
        mute = tag(soap(h, p, "RenderingControl", "GetMute"), "CurrentMute")
        { "state" => STATES.fetch(state.to_s, "idle"), "title" => tag(meta, "title"), "artist" => tag(meta, "creator"), "album" => tag(meta, "album"),
          "volume" => vol&.to_i, "muted" => mute == "1" }.compact
      end

      def run(device, command, value)
        h, p = host(device), port(device, PORT)
        case command
        when "volume" then soap(h, p, "RenderingControl", "SetVolume", "DesiredVolume" => value.to_i.clamp(0, 100))
        when "volume_up", "volume_down" then soap(h, p, "RenderingControl", "SetRelativeVolume", "Adjustment" => command == "volume_up" ? 5 : -5)
        when "mute" then soap(h, p, "RenderingControl", "SetMute", "DesiredMute" => value ? 1 : 0)
        when "play_media"
          soap(h, p, "AVTransport", "SetAVTransportURI", "CurrentURI" => value.to_s, "CurrentURIMetaData" => "")
          soap(h, p, "AVTransport", "Play", "Speed" => 1)
        else
          service, action, args = ACTIONS.fetch(command) { raise Error, "A caixa Sonos não faz #{command}." }
          soap(h, p, service, action, args)
        end
      end
    end
  end
end
