module Integrations
  # Echo da conta Amazon. Lote 3 (G31): sessão própria pelo login da Amazon
  # no navegador da pessoa (Alexa::Auth: 2FA na própria página da Amazon,
  # renovação sozinha pelo refresh token). Colar cookies de uma sessão já
  # logada (Alexa::Import, o caminho antigo) continua valendo.
  class AlexaPlugin < Plugin
    describe key: "alexa", title: "Alexa (Amazon)", icon: "speakerphone",
             description: "Echo da conta Amazon para falar avisos, anunciar e rodar rotinas. Entra com a conta Amazon (com verificação em duas etapas) e renova a sessão sozinho."

    def self.setup(site, form)
      return import(site, form, "Conta da Alexa conectada.") if form[:cookies].present?

      integration = site.integrations.find_or_initialize_by(driver: driver)
      integration.assign_attributes(name: integration.name.presence || "Alexa", status: integration.new_record? ? "pending" : integration.status,
                                    settings: integration.settings.merge("domain" => form[:domain].presence_in(Alexa::Auth::DOMAINS) || Alexa::Auth::DEFAULT_DOMAIN))
      integration.save!
      outcome(:connect, integration: integration)
    end

    # Reconfigurar / passo de login: endereço da página final da Amazon, ou cookies colados.
    def self.login(integration, form)
      return import(integration.site, form, "Conta da Alexa atualizada.", integration) if form[:cookies].present?
      return outcome(:connect, integration: integration, alert: "Cole o endereço da página da Amazon depois de entrar.") if form[:return_url].blank?

      Alexa::Auth.finish!(integration, form[:return_url])
      Alexa::Import.discover!(integration)
      outcome(:index, notice: "Conta da Alexa conectada. A sessão se renova sozinha.")
    rescue Alexa::Client::Error => e
      integration.error!(e)
      outcome(:connect, integration: integration, alert: "Não deu para entrar: #{e.message}")
    end

    def self.connect_locals(integration, _params) = { login_url: Alexa::Auth.start!(integration) }

    def self.import(site, form, notice, integration = nil)
      Alexa::Import.call(site, form[:cookies].to_s)
      outcome(:index, notice: notice)
    rescue Alexa::Client::Error, Drivers::Alexa::Error, JSON::ParserError, TypeError => e
      outcome(integration ? :connect : :form, integration: integration, alert: "Não deu para conectar: #{e.message}")
    end

    def self.custom_sync? = true

    # Lote 9: última fala às Echo como atributo (Alexa::LastCalled), só onde alguém escuta.
    def self.tick(now)
      ActsAsTenant.without_tenant { Integration.where(driver: driver).to_a }.each do |integration|
        ActsAsTenant.with_tenant(integration.tenant) { Alexa::LastCalled.refresh!(integration, now) }
      rescue StandardError => e # rede ou sessão: tenta no próximo minuto, sem parar as outras integrações
        Rails.logger.warn("[alexa] histórico de voz: #{e.message.truncate(160)}")
      end
    end

    def self.sync!(integration)
      r = Alexa::Import.discover!(integration)
      { found: r[:echos], fresh: r[:devices], removed: 0, keys: 0 }
    end
  end
end
