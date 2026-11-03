module Drivers
  # Sonos (integ2): caixa pela UPnP local (HTTP 1400), um reprodutor DLNA com
  # caminhos fixos (Drivers::Dlna). Comando vai para a caixa que recebeu (num
  # grupo, o Sonos repassa ao coordenador o tocar/pausar).
  # ondaC2 (C8/C9): favoritos como biblioteca (`browse`, ContentDirectory
  # FV:2), tocar um favorito (`play_media` "FV:2/…") e grupo nativo: `join`
  # (valor = id do ponto de mídia da caixa que coordena) e `unjoin`.
  class Sonos < Dlna
    PORT = 1400
    SUPPORTS = (Dlna::SUPPORTS + %w[join unjoin]).freeze
    SERVICES = { "AVTransport" => "/MediaRenderer/AVTransport/Control", "RenderingControl" => "/MediaRenderer/RenderingControl/Control" }.freeze
    LIBRARY = "/MediaServer/ContentDirectory/Control".freeze
    FAVORITES = "FV:2".freeze

    class << self
      def base(host, port) = "http://#{host}:#{port}"
      def base_of(device) = base(host(device), port(device, PORT))

      def control_urls(device) = { "av" => "#{base_of(device)}#{SERVICES['AVTransport']}", "rc" => "#{base_of(device)}#{SERVICES['RenderingControl']}" }

      def tag(xml, name) = Upnp.tag(xml, name)

      def description(host, port)
        xml = LanHttp.get("#{base(host, port)}/xml/device_description.xml", raw: true)
        { "udn" => tag(xml, "UDN").to_s.delete_prefix("uuid:"), "room" => tag(xml, "roomName"), "model" => tag(xml, "modelName"), "serial" => tag(xml, "serialNum") }
      end

      # Biblioteca da caixa (Players do media browser): os favoritos do app Sonos.
      def browse(device, _path = nil)
        Upnp.browse("#{base_of(device)}#{LIBRARY}", FAVORITES).map { |i| i.merge("play" => i["id"]) }
      end

      def run(device, command, value)
        case command
        when "join"
          leader = Point.find_by(id: value.to_s)&.device or raise Error, "Caixa do grupo não encontrada."
          raise Error, "Só junta caixas Sonos." unless leader.driver == "sonos"

          av(device, "SetAVTransportURI", "CurrentURI" => "x-rincon:#{description(host(leader), port(leader, PORT))['udn']}", "CurrentURIMetaData" => "")
        when "unjoin" then av(device, "BecomeCoordinatorOfStandaloneGroup")
        when "play_media"
          return super unless value.to_s.start_with?("#{FAVORITES}/")

          fav = Upnp.browse("#{base_of(device)}#{LIBRARY}", value.to_s, metadata: true).first or raise Error, "Favorito não encontrado."
          play(device, fav["url"], fav["meta"].to_s)
        else super
        end
      end
    end
  end
end
