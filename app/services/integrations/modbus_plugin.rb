module Integrations
  # Modbus TCP (catalogo): qualquer aparelho Modbus da rede (medidor de
  # energia, CLP, inversor, ventilação…) com os registradores que a pessoa
  # descreve, uma linha por ponto, como o `modbus:` do YAML do HA:
  #
  #   Nome; endereço; tipo; formato; escala; unidade
  #   Potência; 30775; input; int32; 1; W
  #   Bomba; 12; coil
  #   Temperatura alvo; 400; holding; int16; 0.1; °C
  #
  # tipo: holding (lê e escreve), input, coil (liga/desliga) ou discrete;
  # formato: uint16, int16, uint32, int32, float32 (2 registradores, palavra
  # alta primeiro). Holding de 16 bits e coil recebem comando.
  class ModbusPlugin < SchemaPlugin
    describe key: "modbus", title: "Modbus TCP", icon: "chip",
             description: "Qualquer aparelho Modbus TCP da rede (medidores, CLPs, inversores, ventilação): você descreve os registradores e eles viram pontos, com leitura e escrita."
    texts "pt-BR" => { fields: { unit: "Unidade Modbus (slave id)", registers: "Registradores (um por linha)" },
                       hints: { registers: "Nome; endereço; tipo (holding, input, coil, discrete); formato (uint16, int16, uint32, int32, float32); escala; unidade" },
                       bad_line: "Linha %{n} dos registradores não dá para ler: %{line}", none: "Descreva pelo menos um registrador." },
          en: { title: "Modbus TCP", description: "Any Modbus TCP device on your network (meters, PLCs, inverters, ventilation): you describe the registers and they become points, with read and write.",
                fields: { unit: "Modbus unit (slave id)", registers: "Registers (one per line)" },
                hints: { registers: "Name; address; type (holding, input, coil, discrete); format (uint16, int16, uint32, int32, float32); scale; unit" },
                bad_line: "Register line %{n} can't be read: %{line}", none: "Describe at least one register." },
          es: { title: "Modbus TCP", description: "Cualquier aparato Modbus TCP de la red (medidores, PLCs, inversores, ventilación): describes los registros y se vuelven puntos, con lectura y escritura.",
                fields: { unit: "Unidad Modbus (slave id)", registers: "Registros (uno por línea)" },
                hints: { registers: "Nombre; dirección; tipo (holding, input, coil, discrete); formato (uint16, int16, uint32, int32, float32); escala; unidad" },
                bad_line: "La línea %{n} de los registros no se puede leer: %{line}", none: "Describe al menos un registro." }
    field :host, required: true
    field :port, :number, default: 502
    field :unit, :number, default: 1
    field :registers, :textarea, required: true

    FN = { "holding" => 3, "input" => 4, "coil" => 1, "discrete" => 2 }.freeze
    WORDS = { "uint16" => 1, "int16" => 1, "uint32" => 2, "int32" => 2, "float32" => 2 }.freeze

    class << self
      # Texto → [{name, address, type, format, scale, unit}].
      def registers(text)
        list = text.to_s.lines.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }.each_with_index.map do |line, i|
          name, addr, type, format, scale, unit = line.split(";").map(&:strip)
          type = (type.presence || "holding").downcase
          format = (format.presence || "uint16").downcase
          ok = name.present? && addr.to_s.match?(/\A\d+\z/) && FN.key?(type) && WORDS.key?(format)
          raise Integrations::Error, text(:bad_line, n: i + 1, line: line.truncate(60)) unless ok

          { "name" => name, "address" => addr.to_i, "type" => type, "format" => format, "scale" => (scale.presence || "1").tr(",", ".").to_f, "unit" => unit.presence }
        end
        list.presence || raise(Integrations::Error, text(:none))
      end

      def target(integration) = [ conf(integration, :host), conf(integration, :port).to_i, conf(integration, :unit).to_i ]

      def entries(integration)
        regs = registers(integration.settings["registers"])
        host, port, unit = target(integration)
        Modbus.read(host, port, unit, regs.first["address"], 1, fn: FN[regs.first["type"]]) # confere a conexão
        pts = regs.map do |r|
          bool = %w[coil discrete].include?(r["type"])
          cap = bool ? (r["type"] == "coil" ? "onoff" : "contact") : (r["type"] == "holding" && WORDS[r["format"]] == 1 ? "setpoint" : "measure")
          point("#{r['type']}:#{r['address']}", cap, name: r["name"], unit: r["unit"], address: r.except("name", "unit"),
                **(cap == "setpoint" ? { min: -100_000, max: 100_000, step: r["scale"] } : {}))
        end
        [ entry(id: "modbus:#{host}:#{port}:#{unit}", name: integration.name, manufacturer: "Modbus", model: "#{host}:#{port} · #{unit}", poll_s: 30,
                address: { "host" => host, "port" => port, "unit" => unit }, points: pts) ]
      rescue Modbus::Error => e
        raise Integrations::Error, e.message
      end

      def decode(words, format)
        v = words.size == 2 ? (words[0] << 16) | words[1] : words[0]
        case format
        when "int16" then Modbus.int16(v)
        when "int32" then v >= 0x8000_0000 ? v - 0x1_0000_0000 : v
        when "float32" then [ v ].pack("N").unpack1("g")
        else v
        end
      end

      def read(device)
        a = device.address
        device.points.reject(&:disabled).to_h do |p|
          r = p.address
          fn = FN.fetch(r["type"])
          raw = Modbus.read(a["host"], a["port"], a["unit"], r["address"], fn >= 3 ? WORDS.fetch(r["format"]) : 1, fn: fn)
          [ p.address["field"], fn >= 3 ? (decode(raw, r["format"]) * r["scale"].to_f).round(4) : raw.first ]
        end
      rescue Modbus::Error => e
        raise Integrations::Error, e.message
      end

      def write(point, value)
        a = point.device.address
        r = point.address
        raise Integrations::Error, text(:read_only) unless %w[holding coil].include?(r["type"])

        raw = r["type"] == "coil" ? value == true : (value.to_f / r["scale"].to_f).round
        Modbus.write(a["host"], a["port"], a["unit"], r["address"], raw, fn: r["type"] == "coil" ? 5 : 6)
      rescue Modbus::Error => e
        raise Integrations::Error, e.message
      end
    end
  end
end
