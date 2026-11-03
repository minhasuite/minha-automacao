module Integrations
  # OneDrive (catalogo): conta Microsoft como destino da cópia de segurança de
  # fora de casa (`Backups::Destinations::Onedrive`). A integração só guarda o
  # login (OAuth do app do dono no Azure, escopo da pasta do app: o MA só
  # enxerga a própria pasta "Aplicativos/<app>"). Vale a da instalação da casa
  # (a primeira), como o Google Drive.
  class OnedrivePlugin < OauthPlugin
    describe key: "onedrive", title: "OneDrive (cópia de segurança)", icon: "cloud",
             description: "Guarda a cópia de segurança diária, cifrada, na pasta do app no OneDrive da sua conta Microsoft."
    texts "pt-BR" => { ok: "OneDrive conectado: a próxima cópia de segurança vai para lá.",
                       note: "Crie o app em portal.azure.com → Registros de aplicativo (contas pessoais e corporativas), com o endereço de retorno e a permissão Files.ReadWrite.AppFolder." },
          en: { title: "OneDrive (backup)", description: "Stores the daily encrypted backup in the app folder of your Microsoft account's OneDrive.",
                ok: "OneDrive connected: the next backup goes there.",
                note: "Create the app at portal.azure.com → App registrations (personal and work accounts), with the redirect address and the Files.ReadWrite.AppFolder permission." },
          es: { title: "OneDrive (copia de seguridad)", description: "Guarda la copia de seguridad diaria, cifrada, en la carpeta de la app en el OneDrive de tu cuenta Microsoft.",
                ok: "OneDrive conectado: la próxima copia de seguridad va allí.",
                note: "Crea la app en portal.azure.com → Registros de aplicaciones (cuentas personales y corporativas), con la dirección de retorno y el permiso Files.ReadWrite.AppFolder." }
    oauth authorize: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize", token: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
          scope: "offline_access Files.ReadWrite.AppFolder"
    GRAPH = "https://graph.microsoft.com/v1.0/me/drive".freeze

    class << self
      def entries(_integration) = []
      def custom_sync? = true

      def sync!(integration)
        api(integration, :get, "#{GRAPH}/special/approot")
        integration.ok!
        { found: 0, fresh: 0, removed: 0, keys: 0 }
      rescue Integrations::Error => e
        integration.error!(e.message)
        raise
      end

      def oauth_callback(integration, params)
        o = super
        o.alert ? o : outcome(:index, notice: text(:ok))
      end

      # A integração que vale como destino: a da instalação da casa (primeira), conectada.
      def backup_integration
        ActsAsTenant.without_tenant do
          first = Tenant.order(:created_at, :id).pick(:id)
          Integration.where(tenant_id: first, driver: driver).order(:created_at).find { |i| i.secrets["refresh_token"].present? }
        end
      end
    end
  end
end
