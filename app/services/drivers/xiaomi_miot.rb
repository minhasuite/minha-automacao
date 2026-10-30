module Drivers
  # Xiaomi pelo protocolo local miIO/MIoT (UDP 54321) com o token do aparelho:
  # nada passa pela nuvem nem mexe na conta Xiaomi do HA. Dispositivo:
  # `address` {host, model}, `external_id` = did, `credential` = token (hex,
  # cifrado). Ponto: `address` {siid, piid[, map, decode]} (ver Miio::Vacuum).
  # O estado vem da leitura periódica (`Polling`, `devices.poll_s`; o robô
  # nasce com 60 s); depois de cada comando o aparelho é lido de novo.
  class XiaomiMiot
    class Error < StandardError; end

    def self.client_for(device)
      raise Error, "Dispositivo sem host ou token." if device.address["host"].blank? || device.credential.blank?

      Miio::Client.new(host: device.address["host"], token: device.credential, port: (device.address["port"] || Miio::Client::PORT).to_i)
    end

    # Lê todas as propriedades dos pontos numa chamada e grava os valores.
    def self.poll(device, client: client_for(device))
      points = device.points.reject { |p| p.disabled || p.address["siid"].blank? || p.address["piid"].blank? }
      values = client.get_properties(points.map { |p| [ p.address["siid"].to_i, p.address["piid"].to_i ] }.uniq)
      now = Time.current
      device.update_columns(status: "online", last_seen_at: now)
      points.each do |p|
        key = [ p.address["siid"].to_i, p.address["piid"].to_i ]
        next unless values.key?(key)

        value = Miio::Vacuum.decode(p, values[key])
        p.report!(value, at: now) unless value.nil?
      end
      values.size
    end

    def self.unavailable!(device)
      device.update_columns(status: "offline")
      device.points.each { |p| p.report!(p.value, quality: "unavailable") unless p.quality == "unavailable" }
    end

    def initialize(client: nil)
      @client = client
    end

    def execute(point, command, value)
      device = point.device
      client = @client || self.class.client_for(device)
      if point.capability == "vacuum"
        vacuum(point, command, value, client)
      else
        raise Error, "Ponto sem siid/piid no endereço." if point.address["siid"].blank? || point.address["piid"].blank?

        new_value = Points::Command.new(point, command, value).new_value
        client.set_properties([ [ [ point.address["siid"].to_i, point.address["piid"].to_i ], raw(point, new_value) ] ])
      end
      self.class.poll(device, client: client)
    end

    private

    def vacuum(point, command, value, client)
      args = Points::Command.new(point, command, value).tap(&:new_value).value
      command = "continue" if command == "start" && point.value == "paused"
      siid, aiid = point.address.dig("actions", command) || raise(Error, "O robô não tem a ação #{command}.")
      return client.action(siid, aiid) unless command == "clean_rooms"

      settings = Points::Command.vacuum_settings(point).filter_map do |role, p|
        next if args[role].blank? || args[role] == p.value

        [ [ p.address["siid"].to_i, p.address["piid"].to_i ], raw(p, args[role]) ]
      end
      client.set_properties(settings) if settings.any?
      client.action(siid, aiid, [ args["rooms"].join(",") ])
    end

    def raw(point, value) = point.address["map"] ? Miio::Vacuum.encode(point, value) : point.to_raw(value)
  end
end
