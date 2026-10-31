module Drivers
  # Ponto `media` do Spotify (Pacote 1): comando pela Web API da conta da
  # integração do aparelho e leitura de novo logo depois. Leitura periódica
  # pelo Polling (`poll`/`unavailable!`).
  class Spotify
    def execute(point, command, value)
      value = Points::Command.new(point, command, value).tap(&:new_value).value
      ::Spotify.command(point.device.integration, command, value)
      self.class.poll(point.device)
    end

    def self.poll(device)
      state = ::Spotify.state(device.integration)
      device.update_columns(status: "online", last_seen_at: Time.current)
      device.points.where(capability: "media").find_each { |p| p.report!((p.value.is_a?(Hash) ? p.value : {}).slice("volume").merge(state)) }
    end

    def self.unavailable!(device)
      device.points.find_each { |p| p.report!(p.value, quality: "unavailable") }
    end
  end
end
