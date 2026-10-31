module Drivers
  # Broadlink (Pacote 1): transporte do controle remoto genérico (Remotes).
  # Aparelho: `address` {host, port, mac (hex), devtype}; ponto `remote` com os
  # códigos aprendidos (base64) e, no RM4 Pro, pontos `measure` com
  # `address.sensor` (temperature/humidity). Cada uso abre uma sessão curta
  # (auth + comando): o aparelho não guarda conexão.
  class Broadlink
    def self.client(device)
      a = device.address
      ::Broadlink::Client.new(host: a["host"], port: (a["port"].presence || ::Broadlink::PORT).to_i, mac: a["mac"].to_s, devtype: a["devtype"].to_i).auth!
    end

    # Leitura periódica: o auth prova que está vivo; sensores, se houver.
    def self.poll(device)
      c = client(device)
      sensors = device.points.select { |p| p.address["sensor"].present? }
      values = c.sensors if sensors.any?
      device.update_columns(status: "online", last_seen_at: Time.current)
      sensors.each { |p| p.report!(values[p.address["sensor"]]) }
      device.points.where(capability: "remote").where.not(quality: "good").find_each { |p| p.report!(p.value) }
    end

    def self.unavailable!(device)
      device.update_columns(status: "offline")
      device.points.each { |p| p.report!(p.value, quality: "unavailable") unless p.quality == "unavailable" }
    end

    def execute(point, command, value)
      raise ::Broadlink::Error, "O Broadlink só atende o controle remoto." unless point.capability == "remote"

      Remotes.execute(self, point, command, value.to_s.squish)
    end

    def send_code(point, code) = self.class.client(point.device).send_data(Base64.strict_decode64(code.to_s))

    def learn(point)
      code = self.class.client(point.device).learn
      Base64.strict_encode64(code) if code
    end
  end
end
