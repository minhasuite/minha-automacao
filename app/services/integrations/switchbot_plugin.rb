module Integrations
  # SwitchBot (integ): conta do usuário pela API de nuvem v1.1, com o token e
  # o segredo do app (Drivers::Switchbot). Varre a conta e lista os aparelhos
  # que o mapa conhece (bot, tomada, cortina, termo-higrômetro, sensores,
  # lâmpada, fechadura).
  class SwitchbotPlugin < Plugin
    describe key: "switchbot", title: "SwitchBot", icon: "switch-horizontal",
             description: "Bots, tomadas, cortinas, termo-higrômetros, sensores, lâmpadas e fechaduras SwitchBot pela conta (token do app)."

    def self.setup(site, form)
      return outcome(:form, alert: "Informe o token e o segredo do app SwitchBot.") if form[:token].blank? || form[:secret].blank?

      login(new_integration(site, name: form[:name].to_s.squish.presence || "SwitchBot"), form)
    end

    def self.login(integration, form)
      values = { "token" => form[:token].to_s.strip, "secret" => form[:secret].to_s.strip }.compact_blank
      integration.credentials = integration.secrets.merge(values).to_json if values.any?
      integration.settings = integration.settings.merge("account" => "conta SwitchBot")
      integration.save!
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: "#{r[:found]} aparelho(s) na conta SwitchBot.")
    rescue Integrations::Error => e
      outcome(:found, integration: integration, alert: "Não deu para ler a conta SwitchBot: #{e.message}")
    end

    def self.inventory(integration) = Drivers::Switchbot.inventory(integration)
  end
end
