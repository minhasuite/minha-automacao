module Integrations
  # Smart Life / Tuya Smart por QR code (como a integração `tuya` do HA):
  # aparelhos da conta, inclusive os Zigbee atrás do hub, com estado, comando
  # pela nuvem e tempo real pelo MQTT (Tuya::CloudListener). O que já está no
  # local pelo LocalTuya é o mesmo aparelho e continua com comando local.
  class TuyaPlugin < Plugin
    describe key: "tuya", title: "Tuya / Smart Life", icon: "light-bulb",
             description: "Aparelhos do app Smart Life, inclusive os Zigbee do hub. Entra pelo QR code, como no Home Assistant; o que também está na rede local continua local."

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

    # Lote 9: vídeo da câmera pela nuvem, pedido na hora (ponto `stream` sob demanda).
    def self.stream_url(point) = Tuya::Cloud.new(point.device.integration).stream_url(point.device.external_id)

    # Aparelhos da conta já no local (nuvem ou LocalTuya ligado a ela).
    def self.devices(integration) = integration.devices.where(driver: Tuya::Cloud::DRIVERS, removed_at: nil, disabled: false)

    # Estado da última varredura nos aparelhos; o LocalTuya ligado ganha o
    # código de cada dp (comando sem IP e tempo real pela nuvem).
    def self.refresh(integration)
      by_id = integration.found.index_by { |e| e["id"] }
      devices(integration).includes(:points).find_each do |device|
        e = by_id[device.external_id] or next
        fill_codes(device, e)
        apply(device, e)
      rescue StandardError => ex
        Rails.logger.warn("[tuya] estado de #{device.name}: #{ex.message}")
      end
    end

    # {online, state} da nuvem → aparelho (fora do ar = pontos indisponíveis).
    def self.apply(device, info)
      return Drivers::TuyaLocal.unavailable!(device) if info["online"] == false

      Drivers::TuyaCloud.report(device, info["state"].to_h)
    end

    def self.fill_codes(device, e)
      codes = Array(e["points"]).to_h { |p| [ p.dig("address", "dps").to_s, p.dig("address", "code") ] }
      device.points.each do |p|
        code = codes[p.address["dps"].to_s]
        p.update_columns(address: p.address.merge("code" => code)) if code && p.address["code"] != code
      end
    end
  end
end
