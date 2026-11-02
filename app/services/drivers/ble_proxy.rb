module Drivers
  # Sensores Bluetooth pelo proxy Bluetooth do ESPHome (integ2): a placa
  # ESP32 com `bluetooth_proxy` repassa os anúncios BLE pela API nativa
  # (assinatura 66 com anúncios crus → mensagens 93). Os anúncios viram
  # leituras pelo `Ble`. Aparelho: `external_id` = MAC, `address` {mac}; o
  # proxy (host, porta, chave) fica na integração. Só leitura.
  class BleProxy
    SUBSCRIBE, RAW = 66, 93
    LISTEN_S = 10

    # Ouve o proxy por até `seconds` (ou até ver `until_mac`) → {mac → [modelo, valores]}.
    def self.listen(integration, seconds = LISTEN_S, until_mac: nil)
      s = integration.settings
      k = integration.secrets
      seen = {}
      ::Esphome::Client.open(host: s["host"], port: s["port"], key: k["encryption_key"], password: k["password"]) do |c|
        c.send_message(SUBSCRIBE, [ [ 1, :varint, 1 ] ]) # 1 = anúncios crus
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        while (left = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)).positive?
          type, f = c.read(left)
          break if type.nil?
          next unless type == RAW

          Array(f[1]).each do |raw|
            adv = Proto.decode(raw)
            (r = Ble.decode(adv[4]&.first.to_s)) && (seen[Ble.mac(adv[1]&.first)] = r)
          end
          break if until_mac && seen.key?(until_mac)
        end
      end
      seen
    rescue ::Esphome::Error, *Integrations::LanPlugin::NET_ERRORS => e
      raise Integrations::Error, e.message
    end

    def self.entries(integration)
      listen(integration).map do |mac, (model, values)|
        { "id" => mac, "kind" => "ble_proxy", "name" => "#{model} #{mac[-5..]}", "manufacturer" => model, "category" => "Bluetooth", "online" => true,
          "poll_s" => 300, "address" => { "mac" => mac }, "points" => Ble.points(values) }
      end
    end

    def self.apply(device, values)
      device.update_columns(status: "online", last_seen_at: Time.current)
      device.points.reject(&:disabled).each { |p| (v = values[p.address["field"]]).nil? || p.report!(v) }
    end

    # Ouve até ver este aparelho; os outros do mesmo proxy vistos no caminho também atualizam.
    def self.poll(device)
      seen = listen(device.integration, 30, until_mac: device.address["mac"])
      device.integration.devices.where(driver: "ble_proxy", removed_at: nil).find_each do |d|
        next unless (r = seen[d.address["mac"]])

        apply(d, r[1])
        d.update_columns(polled_at: Time.current) # já lido: a leitura periódica não ouve de novo por ele
      end
      raise Integrations::Error, "#{device.name} não anunciou em 30 s (longe do proxy ou sem bateria?)." unless seen.key?(device.address["mac"])
    end

    def self.unavailable!(device) = Drivers.offline!(device)

    def execute(_point, _command, _value) = raise(Integrations::Error, "Sensor Bluetooth só é lido, não recebe comando.")
  end
end
