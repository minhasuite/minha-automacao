module Ble
  # Descoberta por Bluetooth (resto, 7.23; o `bluetooth` do manifesto do HA):
  # todo anúncio que chega (proxy ESPHome ou adaptador do servidor) deixa um
  # resumo por instalação (nome, fabricante, serviços); o plugin que declara
  # `bluetooth({ local_name: "WoHand*" }, { manufacturer_id: 2409 },
  # { service_uuid: 0xFD3D })` aparece em "Procurar na rede" quando um casa.
  module Discovery
    TTL = 30.minutes
    MAX = 300

    module_function

    def key(tenant_id) = "ble:discovery:#{tenant_id}"
    def seen(tenant_id = ActsAsTenant.current_tenant&.id) = Rails.cache.read(key(tenant_id)) || {}

    # adverts: [{"mac", "rssi", "data" (cru)}].
    def note!(tenant_id, adverts)
      list = seen(tenant_id)
      adverts.each do |a|
        ad = Ble.ads(a["data"])
        next if ad[:name].blank? && ad[:maker].empty? && ad[:service].empty? && ad[:uuids].empty?

        list[a["mac"]] = { "name" => ad[:name], "makers" => ad[:maker].keys, "uuids" => (ad[:service].keys + ad[:uuids]).uniq,
                           "rssi" => a["rssi"], "at" => Time.current.iso8601 }.compact
      end
      Rails.cache.write(key(tenant_id), list.sort_by { |_, v| v["at"] }.last(MAX).to_h, expires_in: TTL)
    end

    # Anúncios que casam → formato do Mdns.browse (a descoberta do plugin).
    def matching(matchers)
      return [] if matchers.blank?

      seen.select { |_, s| matchers.any? { |m| match?(m, s) } }.map do |mac, s|
        { "name" => s["name"].presence || mac, "host" => nil, "port" => nil, "txt" => { "mac" => mac, "rssi" => s["rssi"], "via" => "bluetooth" }.compact }
      end
    end

    def match?(m, s)
      uuid = m[:service_uuid]
      uuid = Integer(uuid.to_s[4, 4], 16) if uuid.is_a?(String) # "0000fd3d-0000-1000-8000-00805f9b34fb" → 0xFD3D
      (m[:local_name].nil? || File.fnmatch?(m[:local_name], s["name"].to_s)) &&
        (m[:manufacturer_id].nil? || Array(s["makers"]).include?(m[:manufacturer_id])) &&
        (uuid.nil? || Array(s["uuids"]).include?(uuid))
    end
  end
end
