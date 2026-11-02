module Integrations
  # Growatt (integ2): usinas solares da conta pela OpenAPI (token da conta), só leitura (Drivers::Growatt).
  class GrowattPlugin < Plugin
    describe key: "growatt", title: "Growatt", icon: "sun",
             description: "Inversores Growatt pela conta ShineServer (token da API): potência de agora e energia do dia e total de cada usina, para os painéis de energia."
    texts "pt-BR" => { need_token: "Informe o token da API da Growatt.", found: "%{n} usina(s) na conta Growatt.", read_failed: "Não deu para ler a conta Growatt: %{error}" },
          en: { title: "Growatt", description: "Growatt inverters through your ShineServer account (API token): current power plus daily and total energy for each plant, for the energy dashboards.", need_token: "Enter your Growatt API token.", found: "%{n} plant(s) found in the Growatt account.", read_failed: "Couldn't read the Growatt account: %{error}" },
          es: { title: "Growatt", description: "Inversores Growatt mediante la cuenta ShineServer (token de la API): potencia actual y energía del día y total de cada planta, para los paneles de energía.", need_token: "Ingresa el token de la API de Growatt.", found: "%{n} planta(s) en la cuenta Growatt.", read_failed: "No se pudo leer la cuenta Growatt: %{error}" }

    def self.setup(site, form)
      return outcome(:form, alert: text(:need_token)) if form[:token].blank?

      login(new_integration(site, name: form[:name].to_s.squish.presence || "Growatt"), form)
    end

    def self.login(integration, form)
      integration.credentials = integration.secrets.merge("token" => form[:token].to_s.strip).to_json if form[:token].present?
      integration.settings = integration.settings.merge("account" => "conta Growatt")
      integration.save!
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: text(:found, n: r[:found]))
    rescue Integrations::Error => e
      outcome(:found, integration: integration, alert: text(:read_failed, error: e.message))
    end

    def self.inventory(integration) = Drivers::Growatt.inventory(integration)
    def self.refresh(integration) = Drivers.refresh(integration)
  end
end
