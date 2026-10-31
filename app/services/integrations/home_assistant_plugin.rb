module Integrations
  # Home Assistant como fonte de referência de uma migração em sombra (F10).
  # Só lê: o diário (logbook) do HA pela API, com um token de acesso longo
  # que a pessoa cria no próprio HA. Não vira aparelho nem ponto.
  #
  # Fonte de referência = plugin de integração que responde a `reference`
  # (e `state_for`); o comparador (Shadow::Compare) não conhece o HA.
  # `reference(integration, from, to, entries:)` → {id da automação ou do
  # script na origem → {"name", "runs", "effects" => [[entidade, estado]]}}.
  class HomeAssistantPlugin < Plugin
    describe key: "home_assistant", title: "Home Assistant (migração)", icon: "switch-horizontal",
             description: "Compara o que as automações em sombra teriam feito com o que o Home Assistant fez de verdade. Só leitura."

    # Domínios cujas mudanças contam como efeito de uma automação (os
    # sensores mudam por conta própria e o HA os atribui ao contexto).
    ACTION_DOMAINS = %w[switch light fan cover lock climate valve siren vacuum humidifier water_heater scene
                        input_boolean input_number input_select input_text input_datetime input_button timer counter select number button].freeze
    RUN_DOMAINS = %w[automation script].freeze
    # Comando daqui → estado que o HA mostraria ("*" = qualquer).
    STATES = { "on" => "on", "off" => "off", "start" => "active", "cancel" => "idle", "finish" => "idle", "pause" => "paused" }.freeze
    COMPARE_HOURS = [ 0, 6, 12, 18 ].freeze
    WINDOW = 24.hours

    def self.setup(site, form)
      integration = new_integration(site, name: title, poll_s: 0)
      configure(integration, form) or return outcome(:form, alert: "Informe o endereço do Home Assistant e um token de acesso longo.")
      integration.save!
      check(integration)
    end

    def self.login(integration, form)
      configure(integration, form) or return outcome(:connect, integration: integration, alert: "Informe o endereço do Home Assistant.")
      integration.save!
      check(integration)
    end

    def self.configure(integration, form)
      url = form[:url].to_s.strip.delete_suffix("/").presence || integration.settings["url"]
      integration.settings = integration.settings.merge("url" => url, "account" => url && URI.parse(url).host)
      integration.credentials = integration.secrets.merge("token" => form[:token].to_s.strip).to_json if form[:token].present?
      url.present? && integration.secrets["token"].present?
    rescue URI::InvalidURIError
      false
    end

    def self.check(integration)
      sync!(integration)
      outcome(:index, notice: "Home Assistant conectado. A comparação roda a cada 6 h e em Sombra → Comparar agora.")
    rescue Integrations::Error => e
      outcome(:index, alert: "Salvo, mas o Home Assistant não respondeu: #{e.message}")
    end

    def self.custom_sync? = true

    # "Testar": GET /api/ (só leitura).
    def self.sync!(integration)
      get(integration, "/api/")
      integration.ok!
      { found: 0, fresh: 0, removed: 0, keys: 0 }
    rescue Integrations::Error => e
      integration.error!(e)
      raise
    end

    def self.get(integration, path)
      res = SafeHttp.get("#{integration.settings['url']}#{path}", headers: { "Authorization" => "Bearer #{integration.secrets['token']}" }, timeout: 60)
      raise Integrations.auth(Integrations::Error.new("token recusado (#{res.status})")) if [ 401, 403 ].include?(res.status)
      raise Integrations::Error, "HTTP #{res.status}" unless res.status == 200

      JSON.parse(res.body)
    rescue SafeHttp::Error, SafeHttp::Blocked, JSON::ParserError => e
      raise Integrations::Error, e.message.truncate(120)
    end

    # A cada 6 h (no minuto 10): compara as últimas 24 h dos locais em sombra.
    def self.tick(now)
      return unless now.min == 10 && COMPARE_HOURS.include?(now.hour)

      ActsAsTenant.without_tenant { Integration.where(driver: driver).includes(:site).to_a }.each do |integration|
        ActsAsTenant.with_tenant(integration.tenant) do
          Shadow::Compare.call(integration.site, key, from: now - WINDOW, to: now, integration: integration)
        rescue StandardError => e
          integration.error!(e)
        end
      end
    end

    # Diário do HA → execuções e efeitos por automação/script.
    def self.reference(integration, from, to, entries: nil)
      entries ||= get(integration, "/api/logbook/#{from.utc.iso8601}?end_time=#{CGI.escape(to.utc.iso8601)}")
      out = Hash.new { |h, k| h[k] = { "name" => nil, "runs" => 0, "effects" => [] } }
      Array(entries).each do |e|
        next unless e.is_a?(Hash)

        domain = e["entity_id"].to_s.split(".").first
        if RUN_DOMAINS.include?(e["domain"]) && e["message"].to_s.start_with?("triggered", "started")
          out[e["entity_id"]]["runs"] += 1
          out[e["entity_id"]]["name"] ||= e["name"]
        elsif e["context_event_type"].present? && RUN_DOMAINS.include?(e["context_entity_id"].to_s.split(".").first) &&
              ACTION_DOMAINS.include?(domain) && e.key?("state")
          out[e["context_entity_id"]]["effects"] << [ e["entity_id"], e["state"].to_s ]
          out[e["context_entity_id"]]["name"] ||= e["context_entity_id_name"] || e["context_name"]
        end
      end
      out
    end

    # Comando daqui → estado do HA ("*" = qualquer: alternar, apertar, rodar).
    def self.state_for(command, value)
      return STATES[command] if STATES.key?(command)

      %w[set select].include?(command) ? value.to_s : "*"
    end
  end
end
