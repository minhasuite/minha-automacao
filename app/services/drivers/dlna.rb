module Drivers
  # Reprodutor DLNA/UPnP (ondaC2, C9; o dlna_dmr do HA): TV, caixa ou
  # receiver que toca um endereço da rede. AVTransport (o que toca, tocar,
  # pausar, avançar) e RenderingControl (volume, mudo) por SOAP; as URLs de
  # controle vêm da descrição do aparelho e ficam em `address` {av, rc}.
  # O Sonos é um DLNA com caminhos fixos e grupos (Drivers::Sonos).
  class Dlna < MediaLan
    SUPPORTS = %w[resume pause next previous volume volume_up volume_down mute play_media].freeze
    STATES = { "PLAYING" => "playing", "PAUSED_PLAYBACK" => "paused", "STOPPED" => "idle", "TRANSITIONING" => "playing",
               "NO_MEDIA_PRESENT" => "idle" }.freeze
    ACTIONS = { "resume" => [ "Play", { "Speed" => 1 } ], "pause" => [ "Pause", {} ], "next" => [ "Next", {} ], "previous" => [ "Previous", {} ] }.freeze
    STEP = 5

    class << self
      def control_urls(device) = device.address.slice("av", "rc")

      def av(device, action, args = {}) = Upnp.soap(control_urls(device).fetch("av"), "AVTransport", action, { "InstanceID" => 0 }.merge(args))
      def rc(device, action, args = {}) = Upnp.soap(control_urls(device).fetch("rc"), "RenderingControl", action, { "InstanceID" => 0, "Channel" => "Master" }.merge(args))

      def read(device)
        meta = Upnp.tag(av(device, "GetPositionInfo"), "TrackMetaData").to_s
        { "state" => STATES.fetch(Upnp.tag(av(device, "GetTransportInfo"), "CurrentTransportState").to_s, "idle"),
          "title" => Upnp.tag(meta, "title"), "artist" => Upnp.tag(meta, "creator"), "album" => Upnp.tag(meta, "album"),
          "volume" => Upnp.tag(rc(device, "GetVolume"), "CurrentVolume")&.to_i, "muted" => Upnp.tag(rc(device, "GetMute"), "CurrentMute") == "1" }.compact
      end

      def run(device, command, value)
        case command
        when "volume" then rc(device, "SetVolume", "DesiredVolume" => value.to_i.clamp(0, 100))
        when "volume_up", "volume_down"
          now = Upnp.tag(rc(device, "GetVolume"), "CurrentVolume").to_i
          rc(device, "SetVolume", "DesiredVolume" => (now + (command == "volume_up" ? STEP : -STEP)).clamp(0, 100))
        when "mute" then rc(device, "SetMute", "DesiredMute" => value ? 1 : 0)
        when "play_media" then play(device, value.to_s)
        else
          action, args = ACTIONS.fetch(command) { raise Error, "O reprodutor não faz #{command}." }
          av(device, action, args)
        end
      end

      def play(device, url, meta = nil)
        av(device, "SetAVTransportURI", "CurrentURI" => url, "CurrentURIMetaData" => meta || didl(url))
        av(device, "Play", "Speed" => 1)
      end

      # Metadado mínimo (muitas TVs recusam tocar sem o protocolInfo).
      def didl(url)
        mime = Cast::TYPES.fetch(File.extname(URI.parse(url).path.to_s).downcase, "audio/mpeg")
        kind = mime.start_with?("video", "application") ? "videoItem" : (mime.start_with?("image") ? "imageItem" : "audioItem.musicTrack")
        %(<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" ) +
          %(xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="-1" restricted="1"><dc:title>Minha Automação</dc:title>) +
          %(<upnp:class>object.item.#{kind}</upnp:class><res protocolInfo="http-get:*:#{mime}:*">#{CGI.escapeHTML(url)}</res></item></DIDL-Lite>)
      rescue URI::InvalidURIError
        raise Error, "Endereço inválido para tocar."
      end
    end
  end
end
