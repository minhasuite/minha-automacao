# Bluetooth (integ2; ondaC1 C2): anúncios BLE crus → leituras, sem conexão.
# Os anúncios chegam do proxy Bluetooth do ESPHome (Drivers::BleProxy) ou do
# adaptador do próprio servidor (bin/ble-scan → Ble::Hub). Cada formato é
# um plugin (`Ble::Parsers`, registro `PARSERS`): BTHome v2 (com e sem
# chave), Xiaomi MiBeacon (com e sem bindkey), termômetros pvvx/ATC, Govee,
# iBeacon (presença e distância) e escovas Oral-B. Campo novo = linha em
# `FIELDS`; formato novo = classe + nome em `PARSERS`.
module Ble
  FIELDS = {
    "temperature" => { "name" => "Temperatura", "unit" => "°C", "device_class" => "temperature" },
    "humidity" => { "name" => "Umidade", "unit" => "%", "device_class" => "humidity" },
    "battery" => { "name" => "Bateria", "unit" => "%", "device_class" => "battery" },
    "pressure" => { "name" => "Pressão", "unit" => "hPa", "device_class" => "pressure" },
    "illuminance" => { "name" => "Luminosidade", "unit" => "lx", "device_class" => "illuminance" },
    "voltage" => { "name" => "Tensão", "unit" => "V", "device_class" => "voltage" },
    "moisture" => { "name" => "Umidade do solo", "unit" => "%", "device_class" => "moisture" },
    "conductivity" => { "name" => "Condutividade", "unit" => "µS/cm", "device_class" => "conductivity" },
    "co2" => { "name" => "CO2", "unit" => "ppm", "device_class" => "carbon_dioxide" },
    "motion" => { "name" => "Movimento", "capability" => "motion" },
    "window" => { "name" => "Abertura", "capability" => "contact" },
    # iBeacon: visto agora (some sozinho sem anúncio) e a distância estimada pelo sinal.
    "presence" => { "name" => "Presença", "capability" => "motion", "device_class" => "presence" },
    "distance" => { "name" => "Distância", "unit" => "m", "device_class" => "distance" },
    "rssi" => { "name" => "Sinal", "unit" => "dBm", "device_class" => "signal_strength" },
    # Oral-B.
    "brushing" => { "name" => "Escovando", "capability" => "motion" },
    "brush_time" => { "name" => "Tempo de escovação", "unit" => "s", "device_class" => "duration" },
    "brush_mode" => { "name" => "Modo", "capability" => "text" },
    "brush_state" => { "name" => "Situação", "capability" => "text" },
    "brush_pressure" => { "name" => "Pressão da escova", "capability" => "text" },
    "sector" => { "name" => "Setor", "unit" => nil }
  }.freeze
  PARSERS = %w[Bthome Xiaomi Pvvx Atc Govee Ibeacon OralB].freeze
  MAC = /\A\h{2}(:\h{2}){5}\z/

  module_function

  def parsers = PARSERS.map { |n| Parsers.const_get(n) }

  def mac(int) = format("%012X", int.to_i).scan(/../).join(":")
  def mac_bytes(mac) = [ mac.to_s.delete(":") ].pack("H*")

  # Estruturas AD → {name:, service: {uuid16 => bytes}, maker: {id => bytes}}.
  def ads(data)
    out = { name: nil, service: {}, maker: {}, uuids: [] }
    pos = 0
    while pos < data.bytesize
      len = data.getbyte(pos)
      break if len.nil? || len.zero? || pos + len >= data.bytesize

      type = data.getbyte(pos + 1)
      body = data.byteslice(pos + 2, len - 1).to_s
      case type
      when 0x08, 0x09 then out[:name] = body.dup.force_encoding("UTF-8").scrub
      when 0x02, 0x03 then out[:uuids].concat(body.unpack("v*")) # resto: serviços anunciados (descoberta)
      when 0x16 then out[:service][body.unpack1("v")] = body.byteslice(2..) if body.bytesize >= 2
      when 0xFF then out[:maker][body.unpack1("v")] = body.byteslice(2..) if body.bytesize >= 2
      end
      pos += len + 1
    end
    out
  end

  # Anúncio cru → [modelo, {campo → valor}(, id próprio)] ou nil (desconhecido,
  # ou cifrado sem a chave). `mac`/`key` decifram BTHome e MiBeacon; `rssi`
  # dá a distância do iBeacon. id próprio (iBeacon: uuid/major/minor) vale
  # no lugar do MAC, que o celular troca.
  def decode(data, mac: nil, rssi: nil, key: nil)
    a = ads(data.b)
    ctx = { mac: mac, rssi: rssi, key: key.presence && [ key.to_s.delete("^0-9a-fA-F") ].pack("H*") }
    parsers.each do |p|
      r = p.parse(a, ctx)
      return r if r && r[1].any?
    end
    nil
  end

  # AES-CCM com etiqueta de 4 bytes (BTHome e MiBeacon v4/v5); nil = chave errada.
  def ccm_decrypt(key, nonce, ct, tag, aad: nil)
    return if key.to_s.bytesize != 16

    c = OpenSSL::Cipher.new("aes-128-ccm").decrypt
    c.iv_len = nonce.bytesize
    c.auth_tag = tag
    c.key = key
    c.iv = nonce
    c.ccm_data_len = ct.bytesize
    c.auth_data = aad if aad
    c.update(ct)
  rescue OpenSSL::Cipher::CipherError
    nil
  end

  # Chaves por MAC (BTHome e bindkey Xiaomi), "AA:BB:CC:DD:EE:FF=chave" separadas por ; ou linha, nos segredos da integração.
  def keys(integration)
    integration.secrets["bindkeys"].to_s.split(/[
;,]/).filter_map do |l|
      mac, key = l.split(/[=\s]+/, 2).map(&:strip)
      [ mac.upcase, key ] if mac.to_s.upcase.match?(MAC) && key.to_s.match?(/\A\h{32}\z/)
    end.to_h
  end

  def points(values)
    values.keys.filter_map do |f|
      spec = FIELDS[f] or next
      { "capability" => "measure", "state_class" => ("measurement" unless spec["capability"]), "writable" => false }.merge(spec).compact.merge("address" => { "field" => f })
    end
  end

  # "Temperatura 22,5 °C · Umidade 50 %" (tela Gerenciar).
  def summary(values)
    values.to_h.filter_map do |f, v|
      spec = FIELDS[f] or next
      v = ActiveSupport::NumberHelper.number_to_delimited(v, locale: I18n.locale) if v.is_a?(Numeric)
      [ spec["name"], v, spec["unit"] ].compact.join(" ")
    end.join(" · ")
  end

  def apply(device, values)
    device.update_columns(status: "online", last_seen_at: Time.current)
    device.points.reject(&:disabled).each { |p| (v = values[p.address["field"]]).nil? || p.report!(v) }
  end
end
