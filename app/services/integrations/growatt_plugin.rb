module Integrations
  # Growatt (integ2): usinas solares da conta pela OpenAPI (token da conta), só leitura (Drivers::Growatt).
  class GrowattPlugin < Plugin
    describe key: "growatt", title: "Growatt", icon: "sun",
             description: "Inversores Growatt pela conta ShineServer (token da API): potência de agora e energia do dia e total de cada usina, para os painéis de energia."

    def self.setup(site, form)
      return outcome(:form, alert: "Informe o token da API da Growatt.") if form[:token].blank?

      login(new_integration(site, name: form[:name].to_s.squish.presence || "Growatt"), form)
    end

    def self.login(integration, form)
      integration.credentials = integration.secrets.merge("token" => form[:token].to_s.strip).to_json if form[:token].present?
      integration.settings = integration.settings.merge("account" => "conta Growatt")
      integration.save!
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: "#{r[:found]} usina(s) na conta Growatt.")
    rescue Integrations::Error => e
      outcome(:found, integration: integration, alert: "Não deu para ler a conta Growatt: #{e.message}")
    end

    def self.inventory(integration) = Drivers::Growatt.inventory(integration)
    def self.refresh(integration) = Drivers.refresh(integration)
  end
end
