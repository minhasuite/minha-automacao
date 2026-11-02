module Drivers
  # Inversor solar SunSpec por Modbus TCP (integ2): o padrão aberto de
  # Fronius, SMA, SolarEdge, Huawei (com SunSpec ligado), WEG, Kehua…
  # Acha o mapa "SunS" (40000, 0 ou 50000), lê o modelo comum (1) e o do
  # inversor (101–103, inteiro + fator de escala). Pontos: potência e energia
  # (alimentam os widgets de energia), tensão, frequência, CC, temperatura e
  # estado. Endereço {host, port, unit, at = registrador do modelo do inversor}.
  class Sunspec
    BASES = [ 40_000, 0, 50_000 ].freeze
    MARK = [ 0x5375, 0x6E53 ].freeze # "SunS"
    INVERTERS = [ 101, 102, 103 ].freeze
    STATES = { 1 => "Desligado", 2 => "Dormindo", 3 => "Iniciando", 4 => "Gerando", 5 => "Limitado", 6 => "Desligando", 7 => "Falha", 8 => "Em espera" }.freeze
    # campo → [posição no modelo, posição do fator de escala, com sinal?]; WH é acc32 em Wh (vira kWh).
    FIELDS = { "W" => [ 12, 13, true ], "PhVphA" => [ 8, 11, false ], "Hz" => [ 14, 15, false ], "DCW" => [ 29, 30, true ],
               "TmpCab" => [ 31, 35, true ] }.freeze
    POINTS = [
      { "name" => "Potência", "capability" => "measure", "unit" => "W", "device_class" => "power", "state_class" => "measurement", "field" => "W" },
      { "name" => "Energia gerada", "capability" => "measure", "unit" => "kWh", "device_class" => "energy", "state_class" => "total_increasing", "field" => "WH" },
      { "name" => "Tensão CA", "capability" => "measure", "unit" => "V", "device_class" => "voltage", "state_class" => "measurement", "field" => "PhVphA" },
      { "name" => "Frequência", "capability" => "measure", "unit" => "Hz", "device_class" => "frequency", "state_class" => "measurement", "field" => "Hz" },
      { "name" => "Potência CC", "capability" => "measure", "unit" => "W", "device_class" => "power", "state_class" => "measurement", "field" => "DCW" },
      { "name" => "Temperatura", "capability" => "measure", "unit" => "°C", "device_class" => "temperature", "state_class" => "measurement", "field" => "TmpCab" },
      { "name" => "Estado", "capability" => "enum", "writable" => false, "options" => STATES.values, "field" => "St" }
    ].freeze

    def self.regs(a, at, n) = Modbus.read(a["host"], a["port"].presence || 502, a["unit"].presence || 1, at, n)
    def self.text(words) = words.pack("n*").delete("\0").force_encoding("UTF-8").scrub.strip

    # → [comum (hash), registrador do modelo do inversor]
    def self.scan(a)
      base = BASES.find { |b| (regs(a, b, 2) rescue nil) == MARK } or raise Integrations::Error, "Não achei o mapa SunSpec (\"SunS\") no inversor."
      at = base + 2
      common = {}
      40.times do
        id, len = regs(a, at, 2)
        break if id == 0xFFFF

        if id == 1
          c = regs(a, at + 2, 66)
          common = { "manufacturer" => text(c[0, 16]), "model" => text(c[16, 16]), "version" => text(c[40, 8]), "serial" => text(c[48, 16]) }
        end
        return [ common, at ] if INVERTERS.include?(id)

        at += 2 + len
      end
      raise Integrations::Error, "O inversor não tem modelo SunSpec de inversor (101–103)."
    end

    def self.entry(integration)
      s = integration.settings
      a = { "host" => s["host"], "port" => (s["port"].presence || 502).to_i, "unit" => (s["unit"].presence || 1).to_i }
      common, at = scan(a)
      { "id" => "sunspec:#{common['serial'].presence || a['host']}", "kind" => "sunspec", "name" => integration.name,
        "manufacturer" => common["manufacturer"].presence || "SunSpec", "model" => common["model"], "category" => "Inversor solar", "online" => true,
        "poll_s" => 30, "address" => a.merge("at" => at), "points" => POINTS.map { |p| p.except("field").merge("address" => { "field" => p["field"] }) } }
    rescue Modbus::Error => e
      raise Integrations::Error, e.message
    end

    def self.scaled(m, pos, sf, signed)
      raw = m[pos + 2]
      return if raw.nil? || raw == (signed ? 0x8000 : 0xFFFF)

      v = signed ? Modbus.int16(raw) : raw
      (v * (10.0**Modbus.int16(m[sf + 2]))).round(3)
    end

    # Bloco do modelo (ID, L e os campos) → {campo → valor}.
    def self.decode(m)
      wh = (m[24] << 16) | m[25]
      FIELDS.to_h { |f, (pos, sf, signed)| [ f, scaled(m, pos, sf, signed) ] }
            .merge("WH" => (wh.zero? || wh == 0xFFFF_FFFF ? nil : (wh * (10.0**Modbus.int16(m[26])) / 1000).round(3)), "St" => STATES[m[38]])
    end

    def self.poll(device)
      a = device.address
      values = decode(regs(a, a["at"].to_i, 52))
      device.update_columns(status: "online", last_seen_at: Time.current)
      device.points.reject(&:disabled).each { |p| (v = values[p.address["field"]]).nil? || p.report!(v) }
    end

    def self.unavailable!(device) = Drivers.offline!(device)

    def execute(_point, _command, _value) = raise(Integrations::Error, "O inversor só é lido, não recebe comando.")
  end
end
