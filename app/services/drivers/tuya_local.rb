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
    # movimento da câmera) ignora o estado completo, que repete a última;
    # ponto `accumulate` (energia `add_ele`) soma o acréscimo ao total.
    def self.report(device, dps, at: Time.current, push: false)
      device.update_columns(status: "online", last_seen_at: at)
      device.points.each do |point|
        dp = point.address["dps"]&.to_s
        next unless dp && dps.key?(dp) && (push || !point.address["push_only"])
        next if point.capability == "remote" # o valor do controle remoto é dos botões aprendidos (Remotes), não do dp

        value = point.from_raw(dps[dp])
        value = point.value.to_f + value if point.address["accumulate"] && value.is_a?(Numeric) # acréscimo → total
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
      return Remotes.execute(self, point, command, value.to_s.squish) if point.capability == "remote" # Pacote 1: hub IR
      dp = point.address["dps"].presence&.to_s or raise Error, "Ponto sem dps no endereço."
      device = point.device
      # Sem IP na rede mas ligado à conta da nuvem: vai pela nuvem (o local é a preferência, não a única via).
      return TuyaCloud.new.execute(point, command, value) if device.address["host"].blank? && point.address["code"].present? && device.integration
      new_value = Points::Command.new(point, command, value).new_value
      dps = point.raw_writes(new_value, "tuya_local")&.to_h { |a, raw| [ a["dps"].to_s, raw ] } || { dp => point.to_raw(new_value) }

      if (live = Tuya::Listener.connection(device.id))
        live.write_dps(dps) # o empurrão de status chega no ouvinte e atualiza o ponto
      else
        conn = self.class.connection_for(device).connect
        begin
          conn.set(dps)
          self.class.report(device, conn.status) # estado completo: medição junto
        ensure
          conn.close
        end
      end
    end

    # Pacote 1: controle remoto pelo hub IR da Tuya (Smart IR, dp 201 manda e
    # aprende, dp 202 traz o código aprendido; endereços vêm do `remotes` do
    # tuya.yml). Transporte do Remotes: `send_code` e `learn`.
    LEARN_S = 20

    def send_code(point, code)
      a = point.address
      ir_write(point.device, a["dps"] => JSON.generate({ control: "send_ir", head: "", key1: "#{a['key_prefix']}#{code}", type: 0, delay: 300 }))
    end

    # ponytail: conexão curta própria; com o ouvinte (`listen`) ligado no hub o
    # aparelho de conexão única pode recusar: desligue o ouvinte para aprender.
    def learn(point)
      a = point.address
      conn = self.class.connection_for(point.device).connect
      begin
        conn.write_dps(a["dps"] => JSON.generate({ control: "study" }))
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LEARN_S
        while (left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)) > 0
          code = conn.read(left)&.dps.to_h[a["learn_dps"].to_s]
          return code if code.present?
        end
        nil
      ensure
        conn.write_dps(a["dps"] => JSON.generate({ control: "study_exit" })) rescue nil # rubocop:disable Style/RescueModifier -- sair do aprendizado é melhor esforço
        conn.close
      end
    end

    private

    def ir_write(device, dps)
      if (live = Tuya::Listener.connection(device.id))
        live.write_dps(dps)
      else
        conn = self.class.connection_for(device).connect
        begin
          conn.write_dps(dps)
        ensure
          conn.close
        end
      end
    end
  end
end
