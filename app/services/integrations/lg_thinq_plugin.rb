module Integrations
  # LG ThinQ (integ2): ACs da conta LG pela API ThinQ Connect, com o token
  # de acesso pessoal (PAT) do usuário (Drivers::LgThinq).
  class LgThinqPlugin < Plugin
    describe key: "lg_thinq", title: "LG ThinQ", icon: "sun",
             description: "Ar-condicionado LG da conta ThinQ pela nuvem oficial (token de acesso pessoal): liga, modo, temperatura e ventilação."

    def self.setup(site, form)
      return outcome(:form, alert: "Informe o token de acesso pessoal da LG.") if form[:token].blank?

      login(new_integration(site, name: form[:name].to_s.squish.presence || "LG ThinQ"), form)
    end

    def self.login(integration, form)
      integration.credentials = integration.secrets.merge("token" => form[:token].to_s.strip).to_json if form[:token].present?
      country = form[:country].to_s.strip.upcase.presence
      integration.settings = integration.settings.merge("account" => "conta LG ThinQ", "client_id" => integration.settings["client_id"] || SecureRandom.uuid,
                                                        "country" => country || integration.settings["country"] || "BR")
      integration.save!
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: "#{r[:found]} ar-condicionado(s) na conta LG.")
    rescue Integrations::Error => e
      outcome(:found, integration: integration, alert: "Não deu para ler a conta LG: #{e.message}")
    end

    def self.inventory(integration) = Drivers::LgThinq.inventory(integration)
    def self.refresh(integration) = Drivers.refresh(integration)
  end
end
