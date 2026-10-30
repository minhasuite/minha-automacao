module Integrations
  # Smart Life / Tuya Smart por QR code (como a integração `tuya` do HA).
  class TuyaPlugin < Plugin
    describe key: "tuya", title: "Tuya / Smart Life", icon: "light-bulb",
             description: "Lâmpadas, tomadas e interruptores do app Smart Life. Entra pelo QR code e acha todos os aparelhos da conta; o controle fica na rede local."

    def self.setup(site, form)
      code = form[:user_code].to_s.strip
      return outcome(:form, alert: "Informe o código de usuário do app.") if code.blank?

      i = new_integration(site, name: "Smart Life", status: "pending", credentials: { "user_code" => code }.to_json)
      i.save!
      outcome(:connect, integration: i)
    end

    def self.login(integration, form)
      integration.merge_secrets!("user_code" => form[:user_code].to_s.strip) if form[:user_code].present?
      outcome(:connect, integration: integration)
    end

    def self.connect_locals(integration, _params)
      # QR = texto da Tuya; o SVG sai do rqrcode, sem texto de fora.
      token = Tuya::Cloud.qr_code(integration.secrets["user_code"])
      integration.merge_secrets!("qr" => token)
      { qr_svg: RQRCode::QRCode.new(Tuya::Cloud.qr_text(token)).as_svg(module_size: 5, standalone: true, use_path: true, viewbox: true).html_safe } # rubocop:disable Rails/OutputSafety -- SVG do rqrcode, sem texto de fora
    end

    def self.logged_in?(integration)
      s = integration.secrets
      info = s["qr"].presence && Tuya::Cloud.login_result(s["qr"], s["user_code"])
      return false unless info

      integration.merge_secrets!(info.except("username").merge("qr" => nil))
      integration.update!(settings: integration.settings.merge("account" => info["username"].presence || "Smart Life"))
      Integrations.start_sync!(integration)
    end

    def self.inventory(integration) = Tuya::Cloud.new(integration).inventory
  end
end
