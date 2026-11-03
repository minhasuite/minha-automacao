module Ble
  # Adaptador Bluetooth do próprio servidor (ondaC1, C2): o serviço
  # `ble-scanner` (bin/ble-scan, HCI cru do Linux, escuta passiva) manda os
  # anúncios em lote para POST /api/v1/bluetooth/advertisements. Aqui eles
  # viram leituras na hora (tempo real, sem esperar a varredura): o último
  # de cada aparelho fica no cache (o "Encontrados" da integração e a tela
  # Gerenciar) e o aparelho adotado recebe o valor. Sem anúncio por
  # `PRESENCE_S`, a presença (iBeacon) volta a falso (tick do plugin).
  module Hub
    TTL = 30.minutes
    MAX = 300
    PRESENCE_S = 180

    module_function

    def key(integration) = "ble:hub:#{integration.id}"
    def read(integration) = Rails.cache.read(key(integration)) || { "seen" => {} }
    def seen(integration) = read(integration)["seen"]

    # adverts: [{"mac", "rssi", "data" (base64)}] → quantos foram entendidos.
    def ingest!(integration, adverts, adapter: nil)
      keys = Ble.keys(integration)
      state = read(integration)
      seen = state["seen"]
      devices = integration.devices.where(driver: "bluetooth", removed_at: nil, disabled: false).includes(:points).index_by(&:external_id)
      count = Array(adverts).first(500).count do |a|
        mac = a["mac"].to_s.upcase
        data = (Base64.strict_decode64(a["data"].to_s) if mac.match?(MAC)) rescue nil # rubocop:disable Style/RescueModifier
        r = data && Ble.decode(data, mac: mac, rssi: a["rssi"].is_a?(Numeric) ? a["rssi"] : nil, key: keys[mac])
        next false unless r

        model, values, id = r
        id ||= mac
        seen[id] = { "mac" => mac, "model" => model, "values" => values, "rssi" => a["rssi"], "at" => Time.current.iso8601 }
        (d = devices[id]) && Ble.apply(d, values)
        true
      end
      seen = seen.sort_by { |_, v| v["at"].to_s }.last(MAX).to_h
      Rails.cache.write(key(integration), { "seen" => seen, "adapter" => adapter.presence || state["adapter"], "at" => Time.current.iso8601 }, expires_in: TTL)
      count
    end

    # Inventário no formato de `Integrations` (o que foi ouvido nos últimos minutos).
    def entries(integration)
      seen(integration).map do |id, s|
        { "id" => id, "kind" => "bluetooth", "name" => id.match?(MAC) ? "#{s['model']} #{id[-5..]}" : s["model"], "manufacturer" => s["model"],
          "category" => "Bluetooth", "online" => true, "poll_s" => 600, "address" => { "mac" => id }, "points" => Ble.points(s["values"].to_h) }
      end
    end

    # Presença vence sem anúncio (iBeacon foi embora).
    def expire_presence!(integration, now = Time.current)
      integration.devices.where(driver: "bluetooth", removed_at: nil).includes(:points).find_each do |d|
        next if d.last_seen_at && d.last_seen_at > now - PRESENCE_S

        d.points.each { |p| p.report!(false) if p.address["field"] == "presence" && p.value == true }
      end
    end
  end
end
