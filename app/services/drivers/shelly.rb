module Drivers
  # Shelly (Pacote 1): comando pelo `Shelly.command` (Gen1 HTTP, Gen2 RPC) e
  # leitura do estado completo logo depois; leitura periódica pelo Polling.
  # Endereço do aparelho {host, port, gen}; senha na integração.
  class Shelly
    def self.conn(device) = device.address.merge("password" => device.integration&.secrets&.dig("password"))

    def self.poll(device)
      status = ::Shelly.status(conn(device))
      device.update_columns(status: "online", last_seen_at: Time.current)
      device.points.each do |p|
        next if p.disabled || p.address["path"].blank?

        value = ::Shelly.value_for(p, status)
        p.report!(value) unless value.nil?
      end
    end

    def self.unavailable!(device)
      device.update_columns(status: "offline")
      device.points.each { |p| p.report!(p.value, quality: "unavailable") unless p.quality == "unavailable" }
    end

    def execute(point, command, value)
      new_value = Points::Command.new(point, command, value).new_value
      ::Shelly.command(self.class.conn(point.device), point, new_value)
      self.class.poll(point.device)
    end
  end
end
