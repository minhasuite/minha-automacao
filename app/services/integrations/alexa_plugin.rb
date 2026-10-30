module Integrations
  # Echo da conta Amazon (cookies de sessão já logada; ver Alexa::Import).
  class AlexaPlugin < Plugin
    describe key: "alexa", title: "Alexa (Amazon)", icon: "speakerphone",
             description: "Echo da conta Amazon para falar avisos e alertas. Usa os cookies de uma sessão já logada."

    def self.setup(site, form) = import(site, form, "Conta da Alexa conectada.")
    def self.login(integration, form) = import(integration.site, form, "Conta da Alexa atualizada.", integration)

    def self.import(site, form, notice, integration = nil)
      Alexa::Import.call(site, form[:cookies].to_s)
      outcome(:index, notice: notice)
    rescue Alexa::Client::Error, Drivers::Alexa::Error, JSON::ParserError, TypeError => e
      outcome(integration ? :connect : :form, integration: integration, alert: "Não deu para conectar: #{e.message}")
    end

    def self.custom_sync? = true

    def self.sync!(integration)
      r = Alexa::Import.discover!(integration)
      { found: r[:echos], fresh: r[:devices], removed: 0, keys: 0 }
    end
  end
end
