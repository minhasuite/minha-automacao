module Drivers
  # ESPHome pela API nativa (Pacote 1). Aparelho: `address` {host, port},
  # `external_id` = MAC; a chave de criptografia e a senha ficam na integração
  # (cifradas). Ponto: `address` {key, kind, field?, position?}. O comando
  # abre uma conexão curta: assina os estados, manda o comando e grava o que
  # o aparelho devolve (sem eco, fica o valor pedido). Tempo real pelo
  # `Esphome::Listener`; `poll` é a leitura de reserva.
  class Esphome
    def self.poll(device, client: ::Esphome.client_for(device))
      client.connect
      client.subscribe_states
      keys = device.points.filter_map { |p| p.address["key"].to_i unless p.address["kind"] == "button" }.uniq
      ::Esphome.report(device, client.states(3, keys))
    ensure
      client&.close
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
      client = @client || ::Esphome.client_for(point.device)
      client.connect
      client.subscribe_states
      client.states(0.3) # estado inicial antes do comando
      client.command(point.address, new_value)
      key = point.address["key"].to_i
      states = client.states(1.5, [ key ])
      ::Esphome.report(point.device, states)
      point.reload.report!(point.capability == "command" ? point.value : new_value) unless states.key?(key)
    ensure
      client&.close
    end
  end
end
