module Drivers
  # Base dos aparelhos de mídia da rede (Pacote 1: Chromecast, LG webOS,
  # Samsung Tizen, Android TV por ADB). O driver só sabe ler o estado
  # (`read` → valor do ponto `media`) e mandar um comando (`run`); comando,
  # leitura periódica e indisponível são daqui. TV desligada não responde na
  # rede: com `off_when_unreachable?` isso vira "Desligada", não "Sem sinal".
  class MediaLan
    class Error < StandardError; end

    NET = [ *Integrations::LanPlugin::NET_ERRORS, WsClient::Error, Error ].freeze

    class << self
      def read(_device) = raise(NotImplementedError)
      def run(_device, _command, _value) = raise(NotImplementedError)
      def off_when_unreachable? = false

      def poll(device)
        value = begin
          read(device)
        rescue *NET
          raise unless off_when_unreachable?

          { "state" => "off" }
        end
        device.update_columns(status: "online", last_seen_at: Time.current)
        media_points(device).each { |p| p.report!(value) }
        value
      end

      def unavailable!(device)
        device.update_columns(status: "offline")
        device.points.each { |p| p.report!(p.value, quality: "unavailable") unless p.quality == "unavailable" }
      end

      def media_points(device) = device.points.select { |p| p.capability == "media" && !p.disabled }
      def host(device) = device.address["host"]
      def port(device, default) = (device.address["port"].presence || default).to_i
      def secrets_owner(device) = device.integration || raise(Error, "Aparelho sem integração.")

      # Wake-on-LAN: pacote mágico por broadcast UDP (porta 9). Só liga TV que tem WoL ativo.
      def wake!(mac)
        hex = mac.to_s.delete(":-")
        raise Error, "Aparelho sem MAC para ligar pela rede." unless hex.match?(/\A\h{12}\z/)

        sock = UDPSocket.new
        sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true)
        sock.send(("\xFF" * 6).b + ([ hex ].pack("H*") * 16), 0, "255.255.255.255", 9)
      ensure
        sock&.close
      end

      # Entrada de inventário de um aparelho de mídia (um ponto `media` com o que ele aceita).
      def entry(integration, id, kind:, supports:, port:, address: {}, manufacturer: nil, model: nil, name: nil)
        { "id" => id, "kind" => kind, "name" => name.presence || integration.name, "manufacturer" => manufacturer, "model" => model,
          "category" => "Mídia", "poll_s" => 60, "address" => { "host" => integration.settings["host"], "port" => port }.merge(address).compact,
          "points" => [ { "name" => "Mídia", "capability" => "media", "history" => "none", "address" => { "supports" => supports } } ] }
      end
    end

    def execute(point, command, value)
      value = Points::Command.new(point, command, value).tap(&:new_value).value
      self.class.run(point.device, command, value)
      self.class.poll(point.device)
    end
  end
end
