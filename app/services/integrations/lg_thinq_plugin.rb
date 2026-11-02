module Integrations
  # LG ThinQ (integ2): ACs da conta LG pela API ThinQ Connect, com o token
  # de acesso pessoal (PAT) do usuário (Drivers::LgThinq).
  class LgThinqPlugin < Plugin
    describe key: "lg_thinq", title: "LG ThinQ", icon: "sun",
             description: "Ar-condicionado LG da conta ThinQ pela nuvem oficial (token de acesso pessoal): liga, modo, temperatura e ventilação."
    texts "pt-BR" => { need_token: "Informe o token de acesso pessoal da LG.", found: "%{n} ar-condicionado(s) na conta LG.", read_failed: "Não deu para ler a conta LG: %{error}" },
          en: { title: "LG ThinQ", description: "LG air conditioners from your ThinQ account through the official cloud (personal access token): power, mode, temperature and fan.", need_token: "Enter your LG personal access token.", found: "%{n} air conditioner(s) found in the LG account.", read_failed: "Couldn't read the LG account: %{error}" },
          es: { title: "LG ThinQ", description: "Aires acondicionados LG de la cuenta ThinQ mediante la nube oficial (token de acceso personal): encendido, modo, temperatura y ventilación.", need_token: "Ingresa el token de acceso personal de LG.", found: "%{n} aire(s) acondicionado(s) en la cuenta LG.", read_failed: "No se pudo leer la cuenta LG: %{error}" }

    def self.setup(site, form)
      return outcome(:form, alert: text(:need_token)) if form[:token].blank?

      login(new_integration(site, name: form[:name].to_s.squish.presence || "LG ThinQ"), form)
    end

    def self.login(integration, form)
      integration.credentials = integration.secrets.merge("token" => form[:token].to_s.strip).to_json if form[:token].present?
      country = form[:country].to_s.strip.upcase.presence
      integration.settings = integration.settings.merge("account" => "conta LG ThinQ", "client_id" => integration.settings["client_id"] || SecureRandom.uuid,
                                                        "country" => country || integration.settings["country"] || "BR")
      integration.save!
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: text(:found, n: r[:found]))
    rescue Integrations::Error => e
      outcome(:found, integration: integration, alert: text(:read_failed, error: e.message))
    end

    def self.inventory(integration) = Drivers::LgThinq.inventory(integration)
    def self.refresh(integration) = Drivers.refresh(integration)
  end
end
