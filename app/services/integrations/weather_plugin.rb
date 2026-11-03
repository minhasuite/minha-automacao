module Integrations
  # Clima (Lote 4, G11): previsão do tempo de um provedor de `Weather::PROVIDERS`
  # (padrão Open-Meteo, sem chave). A localização é a do local (latitude e
  # longitude do cadastro); dá para trocar por outra só nesta integração.
  # Vira um aparelho virtual com o ponto `weather` (condição, agora e previsão)
  # e um `measure` por medida (temperatura, umidade, vento…). A leitura é a
  # varredura da integração (`poll_s`, padrão 30 min).
  class WeatherPlugin < Plugin
    describe key: "weather", title: "Clima", icon: "sun",
             description: "Condição, temperatura e previsão de 7 dias para o local (Open-Meteo, Met.no ou OpenWeatherMap), em pontos, automações e no widget de clima."
    texts "pt-BR" => { connected: "Clima conectado", updated: "Clima atualizado", location_alert: "Informe a latitude e a longitude do local (cadastro do local) ou nesta integração.", read_ok: "%{notice}: %{condition}.", read_failed: "Clima salvo, mas a leitura falhou: %{error}", needs_key: "%{provider} precisa de uma chave." },
          en: { title: "Weather", description: "Conditions, temperature and 7-day forecast for the place (Open-Meteo, Met.no or OpenWeatherMap), in points, automations and the weather widget.", connected: "Weather connected", updated: "Weather updated", location_alert: "Enter the place's latitude and longitude (in the place settings) or in this integration.", read_ok: "%{notice}: %{condition}.", read_failed: "Weather saved, but reading failed: %{error}", needs_key: "%{provider} needs a key." },
          es: { title: "Clima", description: "Condición, temperatura y pronóstico de 7 días para el lugar (Open-Meteo, Met.no u OpenWeatherMap), en puntos, automatizaciones y el widget de clima.", connected: "Clima conectado", updated: "Clima actualizado", location_alert: "Ingresa la latitud y la longitud del lugar (en el registro del lugar) o en esta integración.", read_ok: "%{notice}: %{condition}.", read_failed: "Clima guardado, pero la lectura falló: %{error}", needs_key: "%{provider} necesita una clave." }

    POLL_S = 30 * 60

    def self.setup(site, form)
      integration = new_integration(site, name: form[:name].presence || "Clima", poll_s: POLL_S)
      configure(integration, form) or return outcome(:form, alert: location_alert)
      integration.save!
      read(integration, text(:connected))
    end

    def self.login(integration, form)
      configure(integration, form) or return outcome(:connect, integration: integration, alert: location_alert)
      integration.save!
      read(integration, text(:updated))
    end

    def self.location_alert = text(:location_alert)

    # Provedor, chave e localização do formulário. false = sem localização.
    def self.configure(integration, form)
      provider = Weather.provider(form[:provider].presence || integration.settings["provider"])
      settings = integration.settings.merge("provider" => provider.key)
      # Campos de localização no formulário: preenchidos = própria; vazios = a do local.
      if form.key?(:latitude) || form.key?(:longitude)
        lat = number(form[:latitude])
        lon = number(form[:longitude])
        own = lat && lon && lat.between?(-90, 90) && lon.between?(-180, 180) ? { "latitude" => lat, "longitude" => lon } : {}
        settings = settings.except("latitude", "longitude").merge(own)
      end
      integration.settings = settings.merge("account" => provider.label.split(" (").first)
      integration.credentials = integration.secrets.merge("api_key" => form[:api_key]).to_json if form[:api_key].present?
      location(integration).present?
    end

    def self.number(v) = v.present? ? Float(v.to_s.tr(",", "."), exception: false) : nil

    # [lat, lon] da integração ou do local; nil = sem localização.
    def self.location(integration)
      s = integration.settings
      return [ s["latitude"], s["longitude"] ] if s["latitude"] && s["longitude"]

      site = integration.site
      [ site.latitude.to_f, site.longitude.to_f ] if site.latitude && site.longitude
    end

    def self.read(integration, notice)
      Integrations.sync!(integration)
      outcome(:index, notice: text(:read_ok, notice: notice, condition: Weather.label(device_for(integration).points.find_by(capability: "weather")&.value).downcase))
    rescue Integrations::Error => e
      outcome(:index, alert: text(:read_failed, error: e.message))
    end

    def self.custom_sync? = true

    def self.sync!(integration)
      lat, lon = location(integration) || raise(Integrations::Error, location_alert)
      provider = Weather.provider(integration.settings["provider"])
      raise Integrations::Error, text(:needs_key, provider: provider.label) if provider.needs_key && integration.secrets["api_key"].blank?

      data = provider.fetch(lat: lat, lon: lon, zone: integration.site.timezone, api_key: integration.secrets["api_key"])
      device = device_for(integration)
      Weather.store!(device, data)
      device.update_columns(last_seen_at: Time.current)
      integration.ok!
      { found: 1, fresh: 0, removed: 0, keys: 0 }
    rescue SafeHttp::Error, Weather::Error, Integrations::Error => e
      integration.error!(e.message)
      raise Integrations::Error, e.message
    end

    def self.device_for(integration)
      integration.site.devices.find_or_create_by!(driver: "virtual", external_id: "weather:#{integration.id}") do |d|
        d.name = integration.name
        d.integration = integration
        d.manufacturer = Weather.provider(integration.settings["provider"]).label.split(" (").first
      end
    end
  end
end
