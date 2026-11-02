module Integrations
  # Conta Xiaomi só para listar os aparelhos e buscar os tokens (controle local).
  class XiaomiPlugin < Plugin
    describe key: "xiaomi", title: "Xiaomi (Mi Home)", icon: "vacuum",
             description: "Robô aspirador e aparelhos Mi Home. A conta só serve para achar os aparelhos; o controle fica na rede de casa."
    texts "pt-BR" => { need: "Informe usuário e senha da conta Xiaomi.", captcha: "A Xiaomi pediu a verificação da imagem.", connected: "Conta Xiaomi conectada. Procurando os aparelhos…" },
          en: { title: "Xiaomi (Mi Home)", description: "Robot vacuums and Mi Home devices. The account is only used to find the devices; control stays on your home network.", need: "Enter your Xiaomi account username and password.", captcha: "Xiaomi asked for the image verification.", connected: "Xiaomi account connected. Looking for devices…" },
          es: { title: "Xiaomi (Mi Home)", description: "Robot aspiradora y aparatos Mi Home. La cuenta solo sirve para encontrar los aparatos; el control queda en la red de casa.", need: "Ingresa el usuario y la contraseña de la cuenta Xiaomi.", captcha: "Xiaomi pidió la verificación de la imagen.", connected: "Cuenta Xiaomi conectada. Buscando los aparatos…" }

    def self.setup(site, form)
      i = new_integration(site, name: "Xiaomi", status: "pending")
      return outcome(:connect, integration: i.tap(&:save!), params: { modo: "qr" }) if form[:modo] == "qr"
      return outcome(:form, alert: text(:need)) if form[:username].blank? || form[:password].blank?

      i.save!
      login(i, form)
    end

    def self.login(integration, form)
      values = { "region" => form[:region].to_s }
      values["username"] = form[:username].to_s.strip if form[:username].present?
      values["password"] = form[:password].to_s if form[:password].present?
      integration.merge_secrets!(values)
      integration.update!(settings: integration.settings.merge("account" => integration.secrets["username"]).compact)
      result = Miio::Cloud.new(integration).login(captcha: form[:captcha])
      return outcome(:connect, integration: integration, alert: text(:captcha)) if result == :captcha
      return outcome(:connect, integration: integration, params: { etapa: "2fa" }) if result == :two_factor

      Integrations.start_sync!(integration)
      outcome(:found, integration: integration, notice: text(:connected))
    rescue Miio::Cloud::Error => e
      integration.error!(e)
      outcome(:connect, integration: integration, alert: e.message)
    end

    def self.connect_locals(integration, params)
      return {} unless params[:modo] == "qr"

      { qr_png: Miio::Cloud.new(integration).qr_start }
    end

    # Só lê o estado: quem espera o app confirmar é o XiaomiQrLoginJob.
    def self.logged_in?(integration) = Miio::Cloud.new(integration).qr_done?

    def self.inventory(integration) = Miio::Cloud.new(integration).inventory
  end
end
