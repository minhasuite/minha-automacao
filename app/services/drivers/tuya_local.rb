module Drivers
  # Tuya local (LAN). Ponto ↔ dps por `points.address` ({"dps" => "1"}); em
  # número, valor = bruto × scale + offset (consumo em décimos de W etc.).
  # Com o ouvinte ligado no aparelho (`listen`), o comando sai pela conexão
  # dele e o empurrão de status atualiza o ponto; senão abre uma conexão só
  # para o comando.
  class TuyaLocal
    def self.connection_for(device)
      raise Error, "Dispositivo sem host, device_id ou local_key." if device.address["host"].blank? || device.external_id.blank? || device.credential.blank?

      Tuya::Connection.new(host: device.address["host"], device_id: device.external_id, local_key: device.credential,
                           version: device.address["version"].presence || "3.3", port: (device.address["port"] || Tuya::Connection::PORT).to_i)
    end

    class Error < StandardError; end

    # Grava nos pontos do aparelho os dps recebidos. `push`: veio do aparelho
    # sozinho (ouvinte); ponto `push_only` (mensagem de evento, como o
    # movimento da câmera) ignora o estado completo, que repete a última.
    def self.report(device, dps, at: Time.current, push: false)
      device.update_columns(status: "online", last_seen_at: at)
      device.points.each do |point|
        dp = point.address["dps"]&.to_s
        next unless dp && dps.key?(dp) && (push || !point.address["push_only"])

        value = point.from_raw(dps[dp])
        point.report!(value, at: at) unless value.nil? && point.address["decode"] # decodificado nil = mensagem de outro tipo
      end
    end

    # Leitura periódica (Polling): conexão curta, estado completo, fecha.
    def self.poll(device)
      conn = connection_for(device).connect
      report(device, conn.status)
    ensure
      conn&.close
    end

    # "Reconectar": tenta a versão gravada e depois as outras (só leitura de
    # estado); a que responder fica no endereço do aparelho.
    VERSIONS = %w[3.3 3.4 3.5 3.1].freeze
    def self.reconnect(device)
      error = nil
      ([ device.address["version"] ] + VERSIONS).compact.uniq.each do |v|
        device.address = device.address.merge("version" => v)
        poll(device)
        device.update_columns(address: device.address)
        return v
      rescue StandardError => e
        error = e
      end
      device.restore_attributes([ :address ])
      raise error
    end

    def self.unavailable!(device)
      device.update_columns(status: "offline")
      device.points.each { |p| p.report!(p.value, quality: "unavailable") unless p.quality == "unavailable" }
    end

    def execute(point, command, value)
      dp = point.address["dps"].presence&.to_s or raise Error, "Ponto sem dps no endereço."
      device = point.device
      # Sem IP na rede mas ligado à conta da nuvem: vai pela nuvem (o local é a preferência, não a única via).
      return TuyaCloud.new.execute(point, command, value) if device.address["host"].blank? && point.address["code"].present? && device.integration
      raw = point.to_raw(Points::Command.new(point, command, value).new_value)

      if (live = Tuya::Listener.connection(device.id))
        live.write_dps(dp => raw) # o empurrão de status chega no ouvinte e atualiza o ponto
      else
        conn = self.class.connection_for(device).connect
        begin
          conn.set(dp => raw)
          self.class.report(device, conn.status) # estado completo: medição junto
        ensure
          conn.close
        end
      end
    end
  end
end
