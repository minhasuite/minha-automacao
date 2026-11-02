# Bluetooth (integ2): anúncios BLE crus (vindos do proxy Bluetooth do
# ESPHome) → leituras de sensores comuns, sem conexão e sem chave:
# BTHome v2 (sem criptografia), termômetros Xiaomi com firmware pvvx/ATC e
# Govee H5072/H5075/H5101/H5102. Decodificador novo = um método + uma linha
# em `DECODERS`; campo novo = uma linha em `FIELDS`.
module Ble
  FIELDS = {
    "temperature" => { "name" => "Temperatura", "unit" => "°C", "device_class" => "temperature" },
    "humidity" => { "name" => "Umidade", "unit" => "%", "device_class" => "humidity" },
    "battery" => { "name" => "Bateria", "unit" => "%", "device_class" => "battery" },
    "pressure" => { "name" => "Pressão", "unit" => "hPa", "device_class" => "pressure" },
    "illuminance" => { "name" => "Luminosidade", "unit" => "lx", "device_class" => "illuminance" },
    "voltage" => { "name" => "Tensão", "unit" => "V", "device_class" => "voltage" },
    "moisture" => { "name" => "Umidade do solo", "unit" => "%", "device_class" => "moisture" },
    "motion" => { "name" => "Movimento", "capability" => "motion" },
    "window" => { "name" => "Abertura", "capability" => "contact" }
  }.freeze
  # BTHome v2: id do objeto → [campo, bytes, fator, com sinal?] (só os comuns; id desconhecido encerra a leitura).
  BTHOME = { 0x00 => [ nil, 1 ], 0x01 => [ "battery", 1, 1 ], 0x02 => [ "temperature", 2, 0.01, true ], 0x03 => [ "humidity", 2, 0.01 ],
             0x04 => [ "pressure", 3, 0.01 ], 0x05 => [ "illuminance", 3, 0.01 ], 0x0C => [ "voltage", 2, 0.001 ], 0x21 => [ "motion", 1, nil ],
             0x2D => [ "window", 1, nil ], 0x2E => [ "humidity", 1, 1 ], 0x2F => [ "moisture", 1, 1 ], 0x45 => [ "temperature", 2, 0.1, true ] }.freeze
  DECODERS = %i[bthome pvvx atc govee].freeze

  module_function

  def mac(int) = format("%012X", int.to_i).scan(/../).join(":")

  # Estruturas AD → {name:, service: {uuid16 => bytes}, maker: {id => bytes}}.
  def ads(data)
    out = { name: nil, service: {}, maker: {} }
    pos = 0
    while pos < data.bytesize
      len = data.getbyte(pos)
      break if len.nil? || len.zero? || pos + len >= data.bytesize

      type = data.getbyte(pos + 1)
      body = data.byteslice(pos + 2, len - 1).to_s
      case type
      when 0x08, 0x09 then out[:name] = body.dup.force_encoding("UTF-8").scrub
      when 0x16 then out[:service][body.unpack1("v")] = body.byteslice(2..) if body.bytesize >= 2
      when 0xFF then out[:maker][body.unpack1("v")] = body.byteslice(2..) if body.bytesize >= 2
      end
      pos += len + 1
    end
    out
  end

  # Anúncio cru → [modelo, {campo → valor}] ou nil (desconhecido ou cifrado).
  def decode(data)
    a = ads(data.b)
    DECODERS.each do |d|
      r = send(d, a)
      return r if r && r[1].any?
    end
    nil
  end

  def bthome(a)
    d = a[:service][0xFCD2] or return
    info = d.getbyte(0).to_i
    return if info.anybits?(0x01) # cifrado: precisa da chave

    values = {}
    pos = 1
    while pos < d.bytesize
      spec = BTHOME[d.getbyte(pos)] or break
      field, size, factor, signed = spec
      raw = d.byteslice(pos + 1, size).to_s
      break if raw.bytesize < size

      n = (raw + "\0".b * (4 - size)).unpack1("V")
      n -= 1 << (size * 8) if signed && n >= 1 << ((size * 8) - 1)
      values[field] = factor ? (n * factor).round(2) : n.positive? if field
      pos += 1 + size
    end
    [ a[:name].presence || "BTHome", values ]
  end

  # Termômetro Xiaomi com firmware pvvx (formato próprio, 15 bytes, little-endian).
  def pvvx(a)
    d = a[:service][0x181A]
    return unless d&.bytesize == 15

    _mac, t, h, mv, batt = d.unpack("a6s<S<S<C")
    [ a[:name].presence || "Termômetro pvvx", { "temperature" => t / 100.0, "humidity" => h / 100.0, "voltage" => mv / 1000.0, "battery" => batt } ]
  end

  # Termômetro Xiaomi com firmware ATC1441 (13 bytes, big-endian).
  def atc(a)
    d = a[:service][0x181A]
    return unless d&.bytesize == 13

    _mac, t, h, batt, mv = d.unpack("a6s>CCS>")
    [ a[:name].presence || "Termômetro ATC", { "temperature" => t / 10.0, "humidity" => h.to_f, "battery" => batt, "voltage" => mv / 1000.0 } ]
  end

  # Govee H5072/H5075/H5101/H5102: temperatura e umidade num número de 3 bytes.
  def govee(a)
    d = a[:maker][0xEC88]
    return unless d && d.bytesize >= 5

    v = (d.getbyte(1) << 16) | (d.getbyte(2) << 8) | d.getbyte(3)
    sign = v.anybits?(0x800000) ? -1 : 1
    v &= 0x7FFFFF
    [ a[:name].presence || "Govee", { "temperature" => sign * (v / 1000) / 10.0, "humidity" => (v % 1000) / 10.0, "battery" => d.getbyte(4) & 0x7F } ]
  end

  def points(values)
    values.keys.filter_map do |f|
      spec = FIELDS[f] or next
      { "capability" => "measure", "state_class" => ("measurement" unless spec["capability"]) }.merge(spec).compact.merge("address" => { "field" => f })
    end
  end
end
