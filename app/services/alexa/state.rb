module Alexa
  # G12 (Echo completo): o estado da Echo como pontos, lido como o
  # alexa_media lê (volumes de todas, "não perturbe" de todas e o `playerInfo`
  # de cada Echo ligada), na varredura/leitura periódica da integração. A Echo
  # ganha, além do `speaker` ("Falar"), os pontos de `POINTS` (ponto novo =
  # uma linha): `media` (capacidade genérica de mídia: o widget e o app
  # desenham pela capacidade), "Não perturbe" (onoff) e "Último chamado"
  # (só leitura; marcado pelo Alexa::LastCalled). Nada aqui comanda a Echo.
  module State
    POINTS = {
      "media" => { name: "Mídia", capability: "media", address: { "supports" => %w[resume pause next previous volume play_media] } },
      "dnd" => { name: "Não perturbe", capability: "onoff" },
      "last_called" => { name: "Último chamado", capability: "onoff", writable: false }
    }.freeze
    PLAYER_STATES = { "PLAYING" => "playing", "PAUSED" => "paused" }.freeze

    module_function

    def refresh!(integration, client: Drivers::Alexa.client_for(integration))
      devices = integration.site.devices.where(integration_id: integration.id, driver: "alexa", removed_at: nil).to_a
      return if devices.empty?

      volumes = client.volumes.index_by { |v| v["dsn"] }
      dnd = client.dnd_list.to_h { |d| [ d["deviceSerialNumber"], d["enabled"] == true ] }
      devices.each do |device|
        points = points_for(device)
        info = device.status == "online" ? client.player(Drivers::Alexa.target(device)) : {}
        points["media"].report!(media_value(info, volumes[device.external_id] || {}))
        points["dnd"].report!(dnd[device.external_id]) if dnd.key?(device.external_id)
      end
    end

    # Formato comum da capacidade `media` ({state, title, artist, album, source, image, volume, muted}).
    def media_value(info, vol)
      { "state" => PLAYER_STATES.fetch(info["state"].to_s, "idle"), "title" => info.dig("infoText", "title"),
        "artist" => info.dig("infoText", "subText1"), "album" => info.dig("infoText", "subText2"),
        "source" => info.dig("provider", "providerName"), "image" => info.dig("mainArt", "url"),
        "volume" => vol["speakerVolume"] || info.dig("volume", "volume"),
        "muted" => vol.key?("speakerMuted") ? vol["speakerMuted"] == true : info.dig("volume", "muted") }.compact
    end

    # Os pontos de `POINTS` da Echo (cria o que falta; acha pelo `address.role`).
    def points_for(device)
      POINTS.to_h do |role, d|
        point = device.points.find_by("address->>'role' = ?", role) ||
                device.points.create!(site: device.site, name: d[:name], capability: d[:capability], writable: d.fetch(:writable, true),
                                      history: "on_change", address: { "role" => role }.merge(d[:address].to_h))
        [ role, point ]
      end
    end
  end
end
