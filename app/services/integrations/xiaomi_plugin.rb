module Integrations
  # Conta Xiaomi só para listar os aparelhos e buscar os tokens (controle local).
  class XiaomiPlugin < Plugin
    describe key: "xiaomi", title: "Xiaomi (Mi Home)", icon: "vacuum",
             description: "Robô aspirador e aparelhos Mi Home. A conta só serve para achar os aparelhos; o controle fica na rede de casa."

    def self.setup(site, form)
      i = new_integration(site, name: "Xiaomi", status: "pending")
      return outcome(:connect, integration: i.tap(&:save!), params: { modo: "qr" }) if form[:modo] == "qr"
      return outcome(:form, alert: "Informe usuário e senha da conta Xiaomi.") if form[:username].blank? || form[:password].blank?

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
      return outcome(:connect, integration: integration, alert: "A Xiaomi pediu a verificação da imagem.") if result == :captcha
      return outcome(:connect, integration: integration, params: { etapa: "2fa" }) if result == :two_factor

      Integrations.start_sync!(integration)
      outcome(:found, integration: integration, notice: "Conta Xiaomi conectada. Procurando os aparelhos…")
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
