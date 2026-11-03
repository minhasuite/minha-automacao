module Integrations
  # Electricity Maps / CO2 Signal (catalogo): intensidade de carbono e parte
  # fóssil da rede elétrica da região do local (API v3, token grátis da conta
  # do dono). A parte fóssil alimenta o fluxo de energia do painel.
  class Co2signalPlugin < SchemaPlugin
    describe key: "co2signal", title: "Electricity Maps (CO2 Signal)", icon: "leaf",
             description: "Quanto carbono a rede elétrica da sua região emite agora e a parte fóssil da energia, para o painel de energia e automações (ligar carga quando a rede está limpa)."
    texts "pt-BR" => { fields: { token: "Token da API", zone: "Zona" }, hints: { zone: "vazio = pela posição do local; ou a zona, ex. BR-CS" }, points: { intensity: "Intensidade de carbono", fossil: "Parte fóssil da rede" },
                      note: "Crie a conta grátis em app.electricitymaps.com → Developer → token (só o dono cria).", no_location: "Informe a latitude e a longitude do local ou a zona." },
          en: { title: "Electricity Maps (CO2 Signal)", description: "How much carbon your region's grid emits right now and its fossil share, for the energy dashboard and automations (run loads when the grid is clean).",
                fields: { token: "API token", zone: "Zone" }, hints: { zone: "empty = from the place's location; or the zone, e.g. DE" }, points: { intensity: "Carbon intensity", fossil: "Grid fossil share" },
                      note: "Create the free account at app.electricitymaps.com → Developer → token (only the owner creates it).", no_location: "Set the place's latitude and longitude or the zone." },
          es: { title: "Electricity Maps (CO2 Signal)", description: "Cuánto carbono emite ahora la red eléctrica de tu región y su parte fósil, para el panel de energía y automatizaciones (encender cargas cuando la red está limpia).",
                fields: { token: "Token de la API", zone: "Zona" }, hints: { zone: "vacío = por la ubicación del lugar; o la zona, ej. ES" }, points: { intensity: "Intensidad de carbono", fossil: "Parte fósil de la red" },
                      note: "Crea la cuenta gratis en app.electricitymaps.com → Developer → token (solo el dueño la crea).", no_location: "Indica la latitud y la longitud del lugar o la zona." }
    field :token, secret: true, required: true
    field :zone

    URL = "https://api.electricitymap.org/v3".freeze

    class << self
      def api(integration, path)
        site = integration.site
        zone = integration.settings["zone"].presence
        raise Integrations::Error, text(:no_location) unless zone || (site.latitude && site.longitude)

        q = zone ? { zone: zone } : { lat: site.latitude.to_f.round(3), lon: site.longitude.to_f.round(3) }
        res = SafeHttp.get("#{URL}/#{path}?#{q.to_query}", headers: { "auth-token" => conf(integration, :token).to_s }, timeout: 15)
        body = JSON.parse(res.body)
        e = Integrations::Error.new("Electricity Maps: #{body['message'] || body['error'] || res.status}")
        raise [ 401, 403 ].include?(res.status) ? Integrations.auth(e) : e unless res.status == 200

        body
      rescue SafeHttp::Error, JSON::ParserError => e
        raise Integrations::Error, "Electricity Maps: #{e.message}"
      end

      def entries(integration)
        z = api(integration, "carbon-intensity/latest")["zone"]
        [ entry(id: "co2signal:#{integration.id}", name: [ title.split(" (").first, z ].compact.join(" "), category: "CO₂", poll_s: 900,
                points: [ point("intensity", unit: "gCO2eq/kWh", state_class: "measurement", icon: "leaf"),
                          point("fossil", unit: "%", state_class: "measurement", icon: "leaf") ]) ]
      end

      def read(device)
        ci = api(device.integration, "carbon-intensity/latest")
        mix = api(device.integration, "power-breakdown/latest")
        free = mix["fossilFreePercentage"]
        { "intensity" => ci["carbonIntensity"], "fossil" => free && (100 - free.to_f).round(1) }
      end
    end
  end
end
