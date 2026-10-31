module Drivers
  # Matter pelo python-matter-server (Pacote 1). Dispositivo: `external_id` =
  # node_id, `address` {node}; a URL do servidor fica na integração. Ponto:
  # `address` {node, endpoint, cluster, attribute}; o comando sai pelo mapa
  # (`config/device_maps/matter.yml`, `commands`) como `device_command`. O
  # tempo real é do Matter::Listener; a leitura periódica é reserva.
  class Matter
    class Error < StandardError; end

    def self.url(device) = device.integration&.settings&.dig("url")

    def self.with_client(device, client = nil, &)
      return yield(client) if client

      ::Matter::Client.open(url(device), &)
    end

    def self.poll(device, client: nil)
      with_client(device, client) do |c|
        node = Array(c.nodes).find { |n| n["node_id"].to_s == device.external_id.to_s } or raise Error, "Nó #{device.external_id} não está no servidor Matter."
        ::Matter::Map.apply(device, node)
      end
    end

    def self.unavailable!(device)
      device.update_columns(status: "offline")
      device.points.each { |p| p.report!(p.value, quality: "unavailable") unless p.quality == "unavailable" }
    end

    def initialize(client: nil)
      @client = client
    end

    def execute(point, command, value)
      new_value = Points::Command.new(point, command, value).new_value
      cmd = ::Matter::Map.spec(point)&.dig("commands", command) or raise Error, "Comando #{command} sem mapa para #{point.name}."
      payload = (cmd["extra"] || {}).merge(cmd["arg"] ? { cmd["arg"] => ::Matter::Map.raw(point, new_value) } : {})
      a = point.address
      self.class.with_client(point.device, @client) { |c| c.device_command(a["node"], a["endpoint"], a["cluster"], cmd["name"], payload) }
      point.report!(new_value) # o attribute_updated confirma
    rescue ::Matter::Client::Error => e
      raise Error, e.message
    end
  end
end
