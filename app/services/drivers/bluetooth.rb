module Drivers
  # Sensor Bluetooth ouvido pelo adaptador do servidor (ondaC1, C2). O valor
  # chega na hora pelo Ble::Hub; a leitura periódica só confere se o
  # aparelho ainda anuncia (sem anúncio há STALE = indisponível). Só leitura.
  class Bluetooth
    STALE = 15.minutes

    def self.poll(device)
      s = ::Ble::Hub.seen(device.integration)[device.external_id] if device.integration
      unless s && Time.zone.parse(s["at"].to_s)&.after?(STALE.ago)
        raise Integrations::Error, "#{device.name} não anuncia há mais de #{STALE.in_minutes.to_i} min (longe do servidor ou sem bateria?)."
      end

      ::Ble.apply(device, s["values"].to_h)
    end

    def self.unavailable!(device) = Drivers.offline!(device)

    def execute(_point, _command, _value) = raise(Integrations::Error, "Sensor Bluetooth só é lido, não recebe comando.")
  end
end
