module Integrations
  # Spotify (Pacote 1): conta pelo OAuth com o app da própria pessoa (client
  # id e secret do painel de desenvolvedor do Spotify, cifrados aqui). Vira o
  # aparelho virtual "Spotify" com um ponto `media` (o que toca, em qual
  # aparelho, volume; tocar, pausar, próxima, anterior, volume e tocar
  # playlist/URI pelo `play_media`). Leitura a cada 30 s (Drivers::Spotify).
  class SpotifyPlugin < Plugin
    describe key: "spotify", title: "Spotify", icon: "music-note",
             description: "O que toca no Spotify da conta, com tocar, pausar, volume e tocar playlist. Usa o app que você cria no painel do Spotify."

    SUPPORTS = %w[resume pause next previous volume play_media].freeze
    POLL_S = 30

    def self.setup(site, form)
      id, secret = form[:client_id].to_s.strip, form[:client_secret].to_s.strip
      return outcome(:form, alert: "Informe o Client ID e o Client Secret do app do Spotify.") if id.blank? || secret.blank?

      integration = new_integration(site, name: form[:name].to_s.squish.presence || "Spotify", status: "pending")
      integration.credentials = { "client_id" => id, "client_secret" => secret }.to_json
      integration.save!
      outcome(:connect, integration: integration)
    end

    def self.login(integration, form)
      values = { "client_id" => form[:client_id].to_s.strip, "client_secret" => form[:client_secret].to_s.strip }.compact_blank
      integration.merge_secrets!(values) if values.any?
      outcome(:connect, integration: integration)
    end

    def self.connect_locals(integration, params)
      { auth_url: Spotify.auth_url(integration, params[:redirect_uri], Integrations.oauth_state(integration)), redirect_uri: params[:redirect_uri] }
    end

    def self.oauth_callback(integration, params)
      integration.merge_secrets!(Spotify.exchange(integration, params[:code], params[:redirect_uri]))
      sync!(integration)
      outcome(:index, notice: "Spotify conectado.")
    rescue Integrations::Error, SafeHttp::Error => e
      integration.error!(e.message)
      outcome(:connect, integration: integration, alert: "O Spotify recusou: #{e.message}")
    end

    def self.custom_sync? = true

    # Garante o aparelho e o ponto e grava o estado de agora.
    def self.sync!(integration)
      device = device_for(integration)
      Drivers::Spotify.poll(device)
      integration.ok!
      { found: 1, fresh: 0, removed: 0, keys: 0 }
    rescue SafeHttp::Error, Integrations::Error => e
      integration.error!(e)
      raise e.is_a?(Integrations::Error) ? e : Integrations::Error.new(e.message)
    end

    def self.device_for(integration)
      device = integration.site.devices.find_or_create_by!(driver: "spotify", external_id: "spotify:#{integration.id}") do |d|
        d.assign_attributes(name: integration.name, integration: integration, manufacturer: "Spotify", poll_s: POLL_S)
      end
      device.points.find_by(capability: "media") ||
        device.points.create!(site: device.site, name: "Spotify", key: Integrations.unique_key(device.site, device, "Spotify"),
                              capability: "media", history: "none", address: { "supports" => SUPPORTS })
      device
    end
  end
end
