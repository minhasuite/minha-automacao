module Integrations
  # SwitchBot (integ): conta do usuário pela API de nuvem v1.1, com o token e
  # o segredo do app (Drivers::Switchbot). Varre a conta e lista os aparelhos
  # que o mapa conhece (bot, tomada, cortina, termo-higrômetro, sensores,
  # lâmpada, fechadura).
  class SwitchbotPlugin < Plugin
    describe key: "switchbot", title: "SwitchBot", icon: "switch-horizontal",
             description: "Bots, tomadas, cortinas, termo-higrômetros, sensores, lâmpadas e fechaduras SwitchBot pela conta (token do app)."
    bluetooth({ manufacturer_id: 2409 }, { service_uuid: 0xFD3D }) # resto (7.23): aparece em "Procurar na rede" quando um SwitchBot anuncia perto
    texts "pt-BR" => { need: "Informe o token e o segredo do app SwitchBot.", found: "%{n} aparelho(s) na conta SwitchBot.", failed: "Não deu para ler a conta SwitchBot: %{error}" },
          en: { title: "SwitchBot", description: "SwitchBot bots, plugs, curtains, thermo-hygrometers, sensors, bulbs and locks through your account (app token).", need: "Enter the SwitchBot app token and secret.", found: "%{n} device(s) in the SwitchBot account.", failed: "Couldn't read the SwitchBot account: %{error}" },
          es: { title: "SwitchBot", description: "Bots, enchufes, cortinas, termohigrómetros, sensores, bombillas y cerraduras SwitchBot por la cuenta (token de la app).", need: "Ingresa el token y el secreto de la app SwitchBot.", found: "%{n} aparato(s) en la cuenta SwitchBot.", failed: "No se pudo leer la cuenta SwitchBot: %{error}" }

    def self.setup(site, form)
      return outcome(:form, alert: text(:need)) if form[:token].blank? || form[:secret].blank?

      login(new_integration(site, name: form[:name].to_s.squish.presence || "SwitchBot"), form)
    end

    def self.login(integration, form)
      values = { "token" => form[:token].to_s.strip, "secret" => form[:secret].to_s.strip }.compact_blank
      integration.credentials = integration.secrets.merge(values).to_json if values.any?
      integration.settings = integration.settings.merge("account" => "conta SwitchBot")
      integration.save!
      r = Integrations.sync!(integration)
      outcome(:found, integration: integration, notice: text(:found, n: r[:found]))
    rescue Integrations::Error => e
      outcome(:found, integration: integration, alert: text(:failed, error: e.message))
    end

    def self.inventory(integration) = Drivers::Switchbot.inventory(integration)
  end
end
