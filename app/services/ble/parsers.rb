module Ble
  # Formatos de anúncio BLE como plugins (ondaC1, C2). Cada classe:
  # `parse(ads, ctx)` → [modelo, {campo → valor}(, id)] ou nil. `ads` vem de
  # Ble.ads (nome, dados de serviço por UUID de 16 bits, dados de fabricante
  # por id); `ctx` = {mac:, rssi:, key:} (chave já em bytes).
  module Parsers
    class Base
      def self.parse(_ads, _ctx) = nil
    end

    # BTHome v2 (bthome.io), com ou sem cifra (AES-CCM, chave por aparelho).
    class Bthome < Base
      UUID = 0xFCD2
      # id do objeto → [campo, bytes, fator, com sinal?] (só os comuns; id desconhecido encerra a leitura).
      OBJECTS = { 0x00 => [ nil, 1 ], 0x01 => [ "battery", 1, 1 ], 0x02 => [ "temperature", 2, 0.01, true ], 0x03 => [ "humidity", 2, 0.01 ],
                  0x04 => [ "pressure", 3, 0.01 ], 0x05 => [ "illuminance", 3, 0.01 ], 0x0C => [ "voltage", 2, 0.001 ], 0x12 => [ "co2", 2, 1 ],
                  0x21 => [ "motion", 1, nil ], 0x2D => [ "window", 1, nil ], 0x2E => [ "humidity", 1, 1 ], 0x2F => [ "moisture", 1, 1 ],
                  0x45 => [ "temperature", 2, 0.1, true ] }.freeze

      def self.parse(a, ctx)
        d = a[:service][UUID] or return
        info = d.getbyte(0).to_i
        payload = d.byteslice(1..).to_s
        if info.anybits?(0x01)
          return unless ctx[:key] && ctx[:mac] && payload.bytesize > 8

          nonce = Ble.mac_bytes(ctx[:mac]) + [ UUID ].pack("v") + info.chr + payload.byteslice(-8, 4)
          payload = Ble.ccm_decrypt(ctx[:key], nonce, payload.byteslice(0...-8), payload.byteslice(-4, 4)) or return
        end
        [ a[:name].presence || "BTHome", objects(payload) ]
      end

      def self.objects(d)
        values = {}
        pos = 0
        while pos < d.bytesize
          spec = OBJECTS[d.getbyte(pos)] or break
          field, size, factor, signed = spec
          raw = d.byteslice(pos + 1, size).to_s
          break if raw.bytesize < size

          n = (raw + "\0".b * (4 - size)).unpack1("V")
          n -= 1 << (size * 8) if signed && n >= 1 << ((size * 8) - 1)
          values[field] = factor ? (n * factor).round(2) : n.positive? if field
          pos += 1 + size
        end
        values
      end
    end

    # Xiaomi MiBeacon (UUID 0xFE95): termômetros, sensores de planta, porta e
    # movimento. v4/v5 cifrado precisa da bindkey (AES-CCM, AAD 0x11).
    class Xiaomi < Base
      UUID = 0xFE95
      # objeto → [[campo, formato unpack, fator]]
      OBJECTS = {
        0x1004 => [ [ "temperature", "s<", 0.1 ] ], 0x1006 => [ [ "humidity", "S<", 0.1 ] ], 0x100A => [ [ "battery", "C", 1 ] ],
        0x100D => [ [ "temperature", "s<", 0.1 ], [ "humidity", "S<", 0.1 ] ], 0x1008 => [ [ "moisture", "C", 1 ] ],
        0x1009 => [ [ "conductivity", "S<", 1 ] ], 0x4803 => [ [ "battery", "C", 1 ] ], 0x4C01 => [ [ "temperature", "e", 1 ] ],
        0x4C02 => [ [ "humidity", "C", 1 ] ], 0x4C08 => [ [ "humidity", "e", 1 ] ]
      }.freeze

      def self.parse(a, ctx)
        d = a[:service][UUID] or return
        return if d.bytesize < 5

        fc = d.unpack1("v")
        pid = d.byteslice(2, 2)
        counter = d.byteslice(4, 1)
        pos = 5
        mac = nil
        if fc.anybits?(0x10)
          mac = d.byteslice(pos, 6)
          pos += 6
        end
        if fc.anybits?(0x20)
          cap = d.getbyte(pos).to_i
          pos += cap.anybits?(0x20) ? 3 : 1
        end
        return unless fc.anybits?(0x40)

        payload = d.byteslice(pos..).to_s
        if fc.anybits?(0x08)
          return unless (fc >> 12) >= 4 && ctx[:key] && payload.bytesize > 7 && (mac || ctx[:mac])

          nonce = (mac || Ble.mac_bytes(ctx[:mac]).reverse) + pid + counter + payload.byteslice(-7, 3)
          payload = Ble.ccm_decrypt(ctx[:key], nonce, payload.byteslice(0...-7), payload.byteslice(-4, 4), aad: "\x11".b) or return
        end
        [ a[:name].presence || "Xiaomi #{pid.unpack1('v').to_s(16).upcase}", objects(payload) ]
      end

      def self.objects(d)
        values = {}
        pos = 0
        while pos + 3 <= d.bytesize
          id, len = d.byteslice(pos, 3).unpack("vC")
          body = d.byteslice(pos + 3, len).to_s
          pos += 3 + len
          case id
          when 0x000F then values["motion"] = true # movimento com luz (o lux vem junto)
          when 0x1019 then values["window"] = body.getbyte(0).to_i != 1 # 0 aberta, 1 fechada, 2 aberta há tempo
          else
            offset = 0
            Array(OBJECTS[id]).each do |field, fmt, factor|
              size = { "s<" => 2, "S<" => 2, "C" => 1, "e" => 4 }.fetch(fmt)
              raw = body.byteslice(offset, size)
              break if raw.to_s.bytesize < size

              values[field] = (raw.unpack1(fmt) * factor).round(2)
              offset += size
            end
          end
        end
        values
      end
    end

    # Termômetro Xiaomi com firmware pvvx (formato próprio, 15 bytes, little-endian).
    class Pvvx < Base
      def self.parse(a, _ctx)
        d = a[:service][0x181A]
        return unless d&.bytesize == 15

        _mac, t, h, mv, batt = d.unpack("a6s<S<S<C")
        [ a[:name].presence || "Termômetro pvvx", { "temperature" => t / 100.0, "humidity" => h / 100.0, "voltage" => mv / 1000.0, "battery" => batt } ]
      end
    end

    # Termômetro Xiaomi com firmware ATC1441 (13 bytes, big-endian).
    class Atc < Base
      def self.parse(a, _ctx)
        d = a[:service][0x181A]
        return unless d&.bytesize == 13

        _mac, t, h, batt, mv = d.unpack("a6s>CCS>")
        [ a[:name].presence || "Termômetro ATC", { "temperature" => t / 10.0, "humidity" => h.to_f, "battery" => batt, "voltage" => mv / 1000.0 } ]
      end
    end

    # Govee H5072/H5075/H5101/H5102: temperatura e umidade num número de 3 bytes.
    class Govee < Base
      def self.parse(a, _ctx)
        d = a[:maker][0xEC88]
        return unless d && d.bytesize >= 5

        v = (d.getbyte(1) << 16) | (d.getbyte(2) << 8) | d.getbyte(3)
        sign = v.anybits?(0x800000) ? -1 : 1
        v &= 0x7FFFFF
        [ a[:name].presence || "Govee", { "temperature" => sign * (v / 1000) / 10.0, "humidity" => (v % 1000) / 10.0, "battery" => d.getbyte(4) & 0x7F } ]
      end
    end

    # iBeacon (Apple, 0x004C 02 15): presença e distância estimada pelo sinal
    # (potência calibrada a 1 m); o id é uuid/major/minor (o MAC muda).
    class Ibeacon < Base
      def self.parse(a, ctx)
        d = a[:maker][0x004C]
        return unless d && d.bytesize >= 23 && d.getbyte(0) == 0x02 && d.getbyte(1) == 0x15

        uuid = d.byteslice(2, 16).unpack1("H*").sub(/\A(\h{8})(\h{4})(\h{4})(\h{4})(\h{12})\z/, '\1-\2-\3-\4-\5')
        major, minor, tx = d.byteslice(18, 5).unpack("nnc")
        values = { "presence" => true }
        if (rssi = ctx[:rssi]).is_a?(Numeric) && rssi.negative?
          values["rssi"] = rssi
          values["distance"] = (10**((tx - rssi) / 20.0)).round(1)
        end
        [ a[:name].presence || "iBeacon #{major}/#{minor}", values, "ibeacon:#{uuid}:#{major}:#{minor}" ]
      end
    end

    # Escova Oral-B (fabricante 0x00DC): escovando, tempo, modo, pressão e setor.
    class OralB < Base
      STATES = { 0 => "Desconhecido", 1 => "Iniciando", 2 => "Parada", 3 => "Escovando", 4 => "Carregando", 5 => "Configurando",
                 6 => "Modo avião", 8 => "Menu", 9 => "Desligada", 113 => "Transporte" }.freeze
      MODES = { 0 => "Desligada", 1 => "Limpeza diária", 2 => "Sensível", 3 => "Massagem", 4 => "Branqueamento", 5 => "Limpeza profunda",
                6 => "Língua", 7 => "Turbo" }.freeze
      PRESSURE = { 0 => "Baixa", 50 => "Normal", 114 => "Normal", 54 => "Botão", 118 => "Botão", 82 => "Botão de ligar", 86 => "Botão",
                   90 => "Botão de ligar", 178 => "Alta", 242 => "Alta" }.freeze

      def self.parse(a, _ctx)
        d = a[:maker][0x00DC]
        return unless d && d.bytesize >= 9

        state = d.getbyte(3)
        [ a[:name].presence || "Oral-B", { "brushing" => state == 3, "brush_state" => STATES.fetch(state, STATES[0]), "brush_time" => (d.getbyte(5) * 60) + d.getbyte(6),
                                           "brush_mode" => MODES.fetch(d.getbyte(7), MODES[0]), "brush_pressure" => PRESSURE.fetch(d.getbyte(4), PRESSURE[50]),
                                           "sector" => d.getbyte(8) } ]
      end
    end
  end
end
