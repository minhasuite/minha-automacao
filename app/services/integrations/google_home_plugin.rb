module Integrations
  # Google Home cloud-to-cloud (ondaC1, C6): uma integração por local guarda o
  # projeto do dono no Google Home Developer Console (id do projeto, cliente
  # OAuth daqui e a conta de serviço do HomeGraph, cifrada). A tela Gerenciar
  # mostra o que copiar para lá (URL de fulfillment, autorização e token),
  # gera o segredo do cliente (aparece uma vez), as contas ligadas e pede
  # "Sincronizar com o Google". O que o Google vê sai da tela Expor.
  class GoogleHomePlugin < Plugin
    describe key: "google_home", title: "Google Home", icon: "speakerphone",
             description: "Google Home e Google Assistente pela nuvem (cloud-to-cloud), sem Matter: os pontos marcados em Expor aparecem no app Google Home e atendem por voz."
    texts "pt-BR" => { bad_project: "Id do projeto: letras minúsculas, números e hífen (o do Google Home Developer Console).", bad_account: "Conta de serviço inválida: cole o JSON baixado no Google Cloud (tipo service_account).",
                       saved: "Google Home configurado. Siga os passos da tela.", secret: "Segredo do cliente (aparece só agora; cole no Developer Console): %{secret}",
                       synced: "Pedido de sincronização enviado para %{n} conta(s).", no_account: "Cole a conta de serviço para sincronizar e mandar o estado na hora.",
                       unlinked: "Conta desvinculada.", unknown_action: "Ação desconhecida." },
          en: { title: "Google Home", description: "Google Home and Google Assistant through the cloud (cloud-to-cloud), no Matter: the points checked in Expose show up in the Google Home app and answer by voice.",
                bad_project: "Project id: lowercase letters, digits and hyphen (the one from the Google Home Developer Console).", bad_account: "Invalid service account: paste the JSON downloaded from Google Cloud (type service_account).",
                saved: "Google Home set up. Follow the steps on the screen.", secret: "Client secret (shown only now; paste it in the Developer Console): %{secret}",
                synced: "Sync request sent for %{n} account(s).", no_account: "Paste the service account to sync and report state right away.",
                unlinked: "Account unlinked.", unknown_action: "Unknown action." },
          es: { title: "Google Home", description: "Google Home y Asistente de Google por la nube (cloud-to-cloud), sin Matter: los puntos marcados en Exponer aparecen en la app Google Home y responden por voz.",
                bad_project: "Id del proyecto: minúsculas, números y guion (el del Google Home Developer Console).", bad_account: "Cuenta de servicio no válida: pega el JSON descargado de Google Cloud (tipo service_account).",
                saved: "Google Home configurado. Sigue los pasos de la pantalla.", secret: "Secreto del cliente (se muestra solo ahora; pégalo en el Developer Console): %{secret}",
                synced: "Pedido de sincronización enviado a %{n} cuenta(s).", no_account: "Pega la cuenta de servicio para sincronizar y enviar el estado al instante.",
                unlinked: "Cuenta desvinculada.", unknown_action: "Acción desconocida." }

    PROJECT = /\A[a-z][a-z0-9-]{3,62}\z/

    def self.redirect_uris(integration)
      p = integration.settings["project_id"].to_s
      p.empty? ? [] : [ "https://oauth-redirect.googleusercontent.com/r/#{p}", "https://oauth-redirect-sandbox.googleusercontent.com/r/#{p}" ]
    end

    def self.setup(site, form)
      i = site.integrations.find_or_initialize_by(driver: driver) { |n| n.assign_attributes(name: title, poll_s: 0) }
      login(i, form)
    end

    def self.login(integration, form)
      project = form[:project_id].to_s.strip.downcase.presence || integration.settings["project_id"]
      return outcome(:form, alert: text(:bad_project)) unless project.to_s.match?(PROJECT)

      account = form[:service_account].to_s.strip
      if account.present?
        acc = (JSON.parse(account) rescue nil) # rubocop:disable Style/RescueModifier
        return outcome(:form, alert: text(:bad_account)) unless acc.is_a?(Hash) && acc["type"] == "service_account" && acc["private_key"].to_s.include?("PRIVATE KEY") && acc["client_email"].present?
      end
      integration.settings = integration.settings.merge("project_id" => project, "client_id" => integration.settings["client_id"] || "ma-google-#{SecureRandom.hex(8)}",
                                                        "account" => project)
      integration.save!
      integration.merge_secrets!("service_account" => account) if account.present?
      integration.ok!
      outcome(:panel, integration: integration, notice: text(:saved))
    end

    def self.custom_sync? = true
    def self.sync!(integration) = integration.ok! && { found: 0, fresh: 0, removed: 0 }
    def self.inventory(_integration) = []

    def self.panel? = true

    def self.panel_locals(integration, _params)
      site = integration.site
      { project: integration.settings["project_id"], client_id: integration.settings["client_id"], has_secret: integration.settings["secret_digest"].present?,
        redirect_uris: redirect_uris(integration), service_account: GoogleHome::HomeGraph.configured?(site),
        exposed: GoogleHome.exposed(site), links: GoogleHome::HomeGraph.links(site).includes(:user).order(created_at: :desc).to_a }
    end

    def self.panel_action(integration, action, params)
      notice = case action
      when "secret"
        secret = SecureRandom.urlsafe_base64(32)
        integration.update!(settings: integration.settings.merge("secret_digest" => ApiToken.digest(secret)))
        text(:secret, secret: secret)
      when "sync"
        raise Integrations::Error, text(:no_account) unless GoogleHome::HomeGraph.configured?(integration.site)

        text(:synced, n: GoogleHome::HomeGraph.request_sync!(integration.site))
      when "unlink"
        GoogleHome::HomeGraph.links(integration.site).find(params[:token]).revoke!
        text(:unlinked)
      else raise Integrations::Error, text(:unknown_action)
      end
      outcome(:panel, integration: integration, notice: notice)
    rescue GoogleHome::HomeGraph::Error => e
      raise Integrations::Error, e.message
    end
  end
end
